open Config
       
type t = | Mach of bytes | Elf of bytes | Unknown

exception Unimplemented_binary_type of string

let get_bytes ?verbose:(verbose=false) filename = 
  let ic = open_in_bin filename in
  if (in_channel_length ic < 4) then (* 4 bytes, less than any magic number we're looking for *)
    Unknown
  else
    let magic = InputUtils.input_i32be ic in
    if (verbose) then Printf.printf "opening %s with magic: 0x%x\n" filename magic;
    if (magic = Fat.kFAT_MAGIC) (* cafe babe *) then
      let nfat_arch = InputUtils.input_i32be ic in
      let sizeof_arch_bytes = nfat_arch * Fat.sizeof_fat_arch in
      let fat_arch_bytes = Bytes.create sizeof_arch_bytes in
      really_input ic fat_arch_bytes 0 sizeof_arch_bytes;
      let offset = Fat.get_x86_64_binary_offset fat_arch_bytes nfat_arch in
      match offset with
      | Some (offset, size) ->
	 (*  if (verbose) then Printf.printf "Found %d byte x86_64 binary at offset %d\n" size offset; *)
	 seek_in ic offset;
	 let magic = InputUtils.input_i32be ic in
	 if (magic = MachHeader.kMH_CIGAM_64) then
           begin
             seek_in ic offset;
             let binary = Bytes.create size in
             really_input ic binary 0 size;
             close_in ic;
             Mach binary
           end
	 else
           begin
             close_in ic;
             Unknown
           end
      | None ->
	 close_in ic;
	 Printf.eprintf "ERROR, bad binary: %s\n" filename;
	 Unknown
	   (* feed motherfucking facf  --- backwards cause we read the 32bit int big E style *)
    else if (magic = MachHeader.kMH_CIGAM_64) then
      begin
	seek_in ic 0;  
	let binary = Bytes.create (in_channel_length ic) in
	really_input ic binary 0 (in_channel_length ic);
	close_in ic;
	Mach binary
      end 
    else if (magic = ElfHeader.kMAGIC_ELF) then
      begin
	seek_in ic 0;  
	let binary = Bytes.create (in_channel_length ic) in
	really_input ic binary 0 (in_channel_length ic);
	close_in ic;
	Elf binary
      end
    else
      begin
	close_in ic;
	if (verbose) then Printf.printf "ignoring binary: %s\n" filename;
	Unknown
      end

let analyze config binary =
  let filename = config.filename in
  let analyze  = config.search_term = "" in
  let silent = not analyze && not config.verbose in (* so we respect verbosity if searching*)
  match binary with
  | Mach bytes ->
     let binary = Mach.analyze ~silent:silent ~print_nlist:config.print_nlist ~lc:analyze ~verbose:config.verbose bytes filename in
     if (not config.verbose && analyze) then
       begin
         Printf.printf "Libraries (%d)\n" @@ (binary.Mach.nlibs - 1); (* because 0th element is binary itself *)
         Printf.printf "Exports (%d)\n" @@ binary.Mach.nexports;
         Printf.printf "Imports (%d)\n" @@ binary.Mach.nimports
       end;
     if (not analyze) then
       try
         Mach.find_export_symbol config.search_term binary |> MachExports.print_mach_export_data ~simple:true
(* TODO: add find import symbol *)
       with Not_found ->
         Printf.printf "";
     else 
       if (config.graph) then
         if (config.use_goblin) then
           begin
             let goblin = Mach.to_goblin binary in
             Graph.graph_goblin ~draw_imports:true ~draw_libs:true goblin @@ Filename.basename filename;
           end
         else
           Graph.graph_mach_binary 
             ~draw_imports:true 
             ~draw_libs:true 
             binary 
             (Filename.basename filename)
  (* ===================== *)
  (* ELF *)
  (* ===================== *)
  | Elf binary ->
     (* analyze the binary and print program headers, etc. *)
     let binary = Elf.analyze ~silent:silent ~nlist:config.print_nlist ~verbose:config.verbose ~filename:filename binary in
     if (not analyze) then
       try
         Elf.find_export_symbol config.search_term binary |> Goblin.print_export
       with Not_found ->
         Printf.printf "";
     else
       if (config.graph) then Graph.graph_goblin binary @@ Filename.basename filename;
  | Unknown ->
     raise @@ Unimplemented_binary_type "Unknown binary"
