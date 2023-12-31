begin
	using Pkg
	Pkg.activate("..")
	Pkg.add("ZipFile")

	using NIfTI
	using ZipFile
	
	pkg_dir = dirname(@__DIR__)
	niftyReg_path = joinpath(pkg_dir, "nift_reg_app","bin")
	# @assert isdir(niftyReg_path)
	aladin_path = abspath(joinpath(niftyReg_path,"reg_aladin.exe"))
	f3d_path = abspath(joinpath(niftyReg_path,"reg_f3d.exe"))
	temp_dir = joinpath(pkg_dir,"temp_files")
	zip_filepath = joinpath(pkg_dir, "nift_reg_app.zip")
	output_directory = joinpath(pkg_dir, "nift_reg_app")
end;

function init_()
	# unzip file
	isdir(output_directory) || unzip_file(zip_filepath, pkg_dir)
end

"""
	This function is a high-level wrapper function that wraps all other functions.
	Call `run_registration(v1::Array{Int16, 3}, v2::Array{Int16, 3}, mask::Array{Bool, 3})`.
	For `mask`, areas that need to get registered are with values = true.
"""
function run_registration(v1::Array{Int16, 3}, v2::Array{Int16, 3}, mask::BitArray{3}; BB_offset = 50, del_tmp_files = false, stationary_acq = "v1")
	# swap v1 or v2 if necessary
	if stationary_acq == "v2"
		temp = deepcopy(v1)
		v1 = deepcopy(v2)
		v2 = temp
	end
	# Check args
	x1, y1, num_slice_v1 = size(v1)
	x2, y2, num_slice_v2 = size(v2)
	x3, y3, num_slice_mask = size(mask)
	@assert num_slice_v1 == num_slice_v2 == num_slice_mask
	@assert x1 == x2 == x3
	@assert y1 == y2 == y3
	# get BB
	BB = find_BB(mask, x1, y1, num_slice_v1, BB_offset)
	# create cropped .nii temp_files
	crop_and_convert2nifty(v1, v2, BB)
	# run
	ApplyNiftyReg()
	# get result
	output = postprocess_and_save(BB, x1, y1, num_slice_v1)
	# delete temp files
	if del_tmp_files
		isdir(temp_dir) && remove_all_in_dir(temp_dir)
	end
	return output
end

function run_registration(v1::Array{Int16, 3}, v2::Array{Int16, 3}; del_tmp_files = false, stationary_acq = "v1")
	# swap v1 or v2 if necessary
	if stationary_acq == "v2"
		temp = deepcopy(v1)
		v1 = deepcopy(v2)
		v2 = temp
	end
	# Check args
	x1, y1, num_slice_v1 = size(v1)
	x2, y2, num_slice_v2 = size(v2)
	x3, y3, num_slice_mask = size(mask)
	@assert num_slice_v1 == num_slice_v2 == num_slice_mask
	@assert x1 == x2 == x3
	@assert y1 == y2 == y3
	# get BB
	up, down, left, right
	BB = [1, x1, 1, y1]
	# create cropped .nii temp_files
	crop_and_convert2nifty(v1, v2, BB)
	# run
	ApplyNiftyReg()
	# get result
	output = postprocess_and_save(BB, x1, y1, num_slice_v1)
	# delete temp files
	if del_tmp_files
		isdir(temp_dir) && remove_all_in_dir(temp_dir)
	end
	return output
end

"""
	This function removes a dir and everything in it.
"""
function remove_all_in_dir(directory_path::String)
	for (root, dirs, files) in walkdir(directory_path)
		for file in files
			rm(joinpath(root, file))
		end
		for dir in dirs
			rm(joinpath(root, dir); recursive=true)
		end
	end
	rm(directory_path)
end

"""
	This function unzip a file
"""
function unzip_file(zip_filepath, output_directory)
    # Open the zip file
    z = ZipFile.Reader(zip_filepath)

    # Iterate over the files in the zip archive
    for f in z.files
        # Create the full path for the extracted file
        output_filepath = joinpath(output_directory, f.name)
        
        if splitext(f.name)[end] == ""
            isdir(output_filepath) || mkdir(output_filepath)
            continue
        end

        # Create any parent directories if they don't exist
        mkpath(dirname(output_filepath))

        # Open the output file and write the contents of the file in the zip archive
        open(output_filepath, "w") do io
            write(io, read(f))
        end
    end

    # Close the zip file
    close(z)
end

"""
	This function gets bounding box from mask.
"""
function find_BB(mask, x_, y_, l, offset)
	up, down, left, right = nothing, nothing, nothing, nothing
	# top to buttom
	for x = 1 : x_
		up==nothing || break
		for slice_idx = 1 : l
			for y = 1 : y_
				mask[x, y, slice_idx] && (up=x;break)
			end
			up==nothing || break
		end
	end
	# buttom to top
	for x = x_ : -1 : 1
		down==nothing || break
		for slice_idx = 1 : l
			for y = 1 : y_
				mask[x, y, slice_idx] && (down=x;break)
			end
			down==nothing || break
		end
	end
	# left to right
	for y = 1 : y_
		left==nothing || break
		for slice_idx = 1 : l
			for x = 1 : x_
				mask[x, y, slice_idx] && (left=y;break)
			end
			left==nothing || break
		end
	end
	# right to left
	for y = y_ : -1 : 1
		right==nothing || break
		for slice_idx = 1 : l
			for x = 1 : x_
				mask[x, y, slice_idx] && (right=y;break)
			end
			right==nothing || break
		end
	end
	return [max(1, up-offset), min(x_, down+offset), max(1, left-offset), min(y_, right+offset)]
end

"""
	This function crops images based on `BB` and convert to nifty.
"""
function crop_and_convert2nifty(v1_dicom, v2_dicom, BB)
	# created path to save
	isdir(temp_dir) || mkdir(temp_dir)
	# get BB
	up, down, left, right = BB
	# crop
	v1_dicom_cropped = v1_dicom[up:down, left:right, :]
	v2_dicom_cropped = v2_dicom[up:down, left:right, :]
	# save
	niwrite(joinpath(temp_dir, "v1.nii"), NIfTI.NIVolume(v1_dicom_cropped))
	niwrite(joinpath(temp_dir, "v2.nii"), NIfTI.NIVolume(v2_dicom_cropped))
end

"""
	This function wraps NiftyReg.
"""
function ApplyNiftyReg()
	temp_path = temp_dir
	v1_nii_path = abspath(joinpath(temp_path, "v1.nii"))
	v2_nii_path = abspath(joinpath(temp_path, "v2.nii"))
	aff_out_path = abspath(joinpath(temp_path, "aff.txt"))
	aladin_out_path = abspath(joinpath(temp_path, "aladin.nii"))
	cpp_out_path = abspath(joinpath(temp_path, "cpp.nii"))
	f3d_out_path = abspath(joinpath(temp_path, "registered.nii"))
	
	# aladin first
	aladin_command = `$aladin_path -ref "$v1_nii_path" -flo "$v2_nii_path" -aff "$aff_out_path" -res "$aladin_out_path"`
	isfile(aff_out_path) || (run(aladin_command);)
	
	# then f3d
	f3d_command = `$f3d_path -ref "$v1_nii_path" -flo "$v2_nii_path" -aff "$aff_out_path" -res "$f3d_out_path" -cpp "$cpp_out_path"`
	isfile(cpp_out_path) || (run(f3d_command);)
end

# ╔═╡ 581b8144-1857-446a-94a8-8f58031574e1
"""
	This function corrects the orientation of images and save them.
"""
function postprocess_and_save(BB, x, y, l)
	out_path = joinpath(temp_dir, "registered.nii")
	rslt = niread(out_path)

	# correct orientation
	up, down, left, right = BB
	output = Array{Int16, 3}(undef, x, y, l)
	output[up:down, left:right, :] = rslt
	return output
end
