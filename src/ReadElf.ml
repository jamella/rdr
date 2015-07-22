open Binary
open Config

let debug = false

(* polymorphic variants don't need to be qualified by module
 since they are open and the symbol is unique *)
let symbol_entry_to_goblin_symbol
      ~tol:tol ~libs:libs ~relocs:relocs (soname,install_name) index entry =
  let bind   = (Elf.SymbolTable.get_bind entry.Elf.SymbolTable.st_info |> Elf.SymbolTable.symbol_bind_to_string) in
  let stype  = (Elf.SymbolTable.get_type entry.Elf.SymbolTable.st_info |> Elf.SymbolTable.symbol_type_to_string) in
  let name   = `Name entry.Elf.SymbolTable.name in
  let offset =
    `Offset (
       if (entry.Elf.SymbolTable.st_value = 0) then
	 (* this _could_ be relatively expensive *)
	 Elf.Reloc.get_size index relocs
       else
	 entry.Elf.SymbolTable.st_value)
  in
  let size = `Size entry.Elf.SymbolTable.st_size in
  let kind = `Kind (Elf.SymbolTable.get_goblin_kind entry bind stype) in
  let lib =
    (* TODO: this is a complete disaster; *)
    match kind with
    | `Kind GoblinSymbol.Export ->
       `Lib (soname,install_name)
    | `Kind GoblinSymbol.Import ->
       if (ToL.is_empty tol) then
	 `Lib ("∅","∅")
       else
	 let l = (ToL.get_libraries ~bin_libs:libs entry.Elf.SymbolTable.name tol) in
	 `Lib (l,l)
    | _ ->
       `Lib ("","")
  in
  let data = `PrintableData
	      (Printf.sprintf
		 "%s %s" bind stype) in
  [name; lib; offset; size; kind; data]

let symbols_to_goblin ?use_tol:(use_tol=true) ~libs:libs soname dynsyms relocs =
  let tol =
    try
      if (use_tol) then ToL.get () else ToL.empty
    with ToL.Not_built ->
      ToL.empty
  in
  List.mapi
    (symbol_entry_to_goblin_symbol
       ~tol:tol ~libs:libs ~relocs:relocs soname) dynsyms

let create_goblin_binary soname install_name libraries islib goblin_exports goblin_imports =
  let name = soname in
  let install_name = install_name in
  let libs = Array.of_list (soname::libraries) in (* to be consistent... for graphing, etc. *)
  let nlibs = Array.length libs in
  let exports =
    Array.of_list
    @@ List.map (GoblinSymbol.to_goblin_export) goblin_exports
  in
  let nexports = Array.length exports in
  let imports =
    Array.of_list
    @@ List.map (GoblinSymbol.to_goblin_import) goblin_imports
  in
  let nimports = Array.length imports in
  (* empty code *)
  let code = Bytes.empty in
  {Goblin.name;
   install_name; islib; libs; nlibs; exports; nexports;
   imports; nimports; code}

let analyze config binary =
  let header = Elf.Header.get_elf_header64 binary in
  let program_headers =
    Elf.ProgramHeader.get_program_headers
      binary
      header.Elf.Header.e_phoff
      header.Elf.Header.e_phentsize
      header.Elf.Header.e_phnum
  in
  let slide_sectors =
    Elf.ProgramHeader.get_slide_sectors program_headers
  in
  let section_headers =
    Elf.SectionHeader.get_section_headers
      binary
      header.Elf.Header.e_shoff
      header.Elf.Header.e_shentsize
      header.Elf.Header.e_shnum
  in
  if (not config.silent) then
    begin
      if (not config.search) then Elf.Header.print_elf_header64 header;
      if (config.verbose || config.print_headers) then
	begin
	  Elf.ProgramHeader.print_program_headers program_headers;
	  Elf.SectionHeader.print_section_headers section_headers
	end;
    end;
  if (not (Elf.Header.is_supported header)) then
    (* for relocs, esp /usr/lib/crt1.o *)
    create_goblin_binary
      config.name config.install_name [] false [] []
  else
    let is_lib = (Elf.Header.is_lib header) in
    let symbol_table = Elf.SymbolTable.get_symbol_table binary section_headers in
    let _DYNAMIC = Elf.Dynamic.get_dynamic binary program_headers in
    let symtab_offset, strtab_offset, strtab_size =
      Elf.Dynamic.get_dynamic_symbol_offset_data _DYNAMIC slide_sectors
    in
    let dynamic_strtab =
      Elf.Dynamic.get_dynamic_strtab binary strtab_offset strtab_size
    in
    let libraries = Elf.Dynamic.get_libraries _DYNAMIC dynamic_strtab in
    let dynamic_symbols =
      Elf.Dynamic.get_dynamic_symbols
	binary
	slide_sectors
	symtab_offset
	strtab_offset
	strtab_size
    in
    let soname =
      try 
	let offset = Elf.Dynamic.get_soname_offset _DYNAMIC in
	Binary.string binary (strtab_offset + offset)
      with Not_found -> config.name (* we're not a dylib *)
    in
    let relocs =
      Elf.Dynamic.get_reloc_data _DYNAMIC slide_sectors
      |> Elf.Reloc.get_relocs64 binary
    in
    let goblin_symbols =
      symbols_to_goblin
	~use_tol:config.use_tol
	~libs:libraries
	(soname,config.install_name)
	dynamic_symbols
	relocs
      |> GoblinSymbol.sort_symbols
      |> function | [] -> [] | syms -> List.tl syms
      (* because the head (the first entry, after sorting)
         is a null entry, and also _DYNAMIC can be empty *)
    in
    let goblin_imports =
      List.filter
	(fun symbol ->
	 GoblinSymbol.find_symbol_kind symbol
	 |> function
	   | GoblinSymbol.Import -> true
	   | _ -> false) goblin_symbols
    in
    let goblin_exports =
      List.filter
	(fun symbol ->
	 GoblinSymbol.find_symbol_kind symbol
	 |> function
	   | GoblinSymbol.Export -> true
	   | _ -> false) goblin_symbols
    in
    (* print switches *)
    if (not config.silent) then
      begin
	if (config.print_headers) then Elf.Dynamic.print_dynamic _DYNAMIC;
	if (config.print_nlist) then
	  symbols_to_goblin ~use_tol:config.use_tol ~libs:libraries (soname,config.install_name) symbol_table relocs
	  |> GoblinSymbol.sort_symbols
	  |> List.iter
	       (GoblinSymbol.print_symbol_data ~like_nlist:true);
	if (config.verbose || config.print_libraries) then
	  begin
	    if (is_lib) then Printf.printf "Soname: %s\n" soname;
	    Printf.printf "Libraries (%d)\n" (List.length libraries);
	    List.iter (Printf.printf "\t%s\n") libraries
	  end;
	if (config.verbose || config.print_exports) then
	  begin
	    Printf.printf "Exports (%d)\n" (List.length goblin_exports);
	    List.iter (GoblinSymbol.print_symbol_data) goblin_exports
	  end;
	if (config.verbose || config.print_imports) then
	  begin
	    Printf.printf "Imports (%d)\n" (List.length goblin_imports);
	    List.iter (GoblinSymbol.print_symbol_data ~with_lib:true) goblin_imports
	  end
      end;
    (* ============== *)
    (* create goblin binary *)
    create_goblin_binary
      soname      
      config.install_name
      libraries
      is_lib
      goblin_exports
      goblin_imports    

let find_export_symbol symbol binary = Goblin.get_export symbol binary.Goblin.exports