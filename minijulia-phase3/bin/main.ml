let usage = {|
MiniJulia 0.3 - Phase 3: Native Compilation

Usage:
  minijulia <file.jl>          Run with VM (default)
  minijulia -i <file.jl>       Run with interpreter
  minijulia compile <f.jl>     Compile to bytecode (.mjc)
  minijulia run <f.mjc>        Run precompiled bytecode
  minijulia build <f.jl>       Compile to native binary
  minijulia build <f.jl> -o X  Compile to native binary named X
  minijulia disasm <f.jl>      Show disassembly
  minijulia dump-c <f.jl>      Show generated C code
  minijulia bench <f.jl>       Benchmark all 3 modes
  minijulia -e "code"          Run inline code
|}

let read_file path =
  let ic = open_in path in
  let n  = in_channel_length ic in
  let s  = Bytes.create n in
  really_input ic s 0 n; close_in ic;
  Bytes.to_string s

let compile_to_chunk file =
  let src = read_file file in
  let prog = Parser.parse src in
  Compiler.compile_program ~source:file prog

let build_native file outfile =
  let chunk   = compile_to_chunk file in
  let c_file  = outfile ^ ".c" in
  Codegen.codegen chunk c_file;
  Printf.printf "Generated C: %s\n%!" c_file;
  let cmd = Printf.sprintf "gcc -O2 -include ctype.h -o %s %s -lm 2>&1" outfile c_file in
  let ret = Sys.command cmd in
  if ret = 0 then
    Printf.printf "Compiled:    %s\n%!" outfile
  else begin
    Printf.eprintf "gcc failed (exit %d)\n" ret;
    exit 1
  end

let () =
  match Array.to_list Sys.argv |> List.tl with
  | [] -> Interpreter.repl ()
  | ["--help"] | ["-h"] -> print_string usage
  | ["-e"; code] ->
      let prog  = Parser.parse code in
      let chunk = Compiler.compile_program prog in
      ignore (Vm.run_chunk chunk (Vm.make_global ()))
  | ["compile"; file] ->
      let chunk = compile_to_chunk file in
      let out   = Filename.remove_extension file ^ ".mjc" in
      Vm.save_bytecode chunk out
  | ["run"; file] when Filename.check_suffix file ".mjc" ->
      let chunk = Vm.load_bytecode file in
      ignore (Vm.run_chunk chunk (Vm.make_global ()))
  | ["build"; file] ->
      let out = Filename.remove_extension file in
      build_native file out
  | ["build"; file; "-o"; out] ->
      build_native file out
  | ["disasm"; file] ->
      let chunk = compile_to_chunk file in
      Bytecode.disassemble chunk
  | ["dump-c"; file] ->
      let chunk  = compile_to_chunk file in
      let c_file = "/tmp/mj_dump.c" in
      Codegen.codegen chunk c_file;
      print_string (read_file c_file)
  | ["bench"; file] ->
      let src = read_file file in
      Printf.printf "Benchmark: %s\n\n" file;
      (* Interpreter *)
      let t0 = Unix.gettimeofday () in
      let g  = Interpreter.make_global () in
      Interpreter.exec_stmts g (Parser.parse src);
      let t1 = Unix.gettimeofday () in
      Printf.printf "Interpreter: %.4fs\n" (t1 -. t0);
      (* VM *)
      let t2    = Unix.gettimeofday () in
      let chunk = Compiler.compile_program ~source:file (Parser.parse src) in
      ignore (Vm.run_chunk chunk (Vm.make_global ()));
      let t3 = Unix.gettimeofday () in
      Printf.printf "Bytecode VM: %.4fs\n" (t3 -. t2);
      (* Native *)
      let out = "/tmp/mj_bench_native" in
      build_native file out;
      let t4 = Unix.gettimeofday () in
      ignore (Sys.command (out ^ " > /dev/null 2>&1"));
      let t5 = Unix.gettimeofday () in
      Printf.printf "Native bin:  %.4fs\n" (t5 -. t4);
      Printf.printf "\n";
      let base = t1 -. t0 in
      let vm_t = t3 -. t2 in
      let nat  = t5 -. t4 in
      if vm_t > 0.0 then Printf.printf "VM speedup:     %.1fx\n" (base /. vm_t);
      if nat  > 0.0 then Printf.printf "Native speedup: %.1fx\n" (base /. nat)
  | ["-i"; file] -> Interpreter.run_file file
  | [file] when Filename.check_suffix file ".mjc" ->
      let chunk = Vm.load_bytecode file in
      ignore (Vm.run_chunk chunk (Vm.make_global ()))
  | [file] ->
      let prog  = Parser.parse (read_file file) in
      let chunk = Compiler.compile_program ~source:file prog in
      ignore (Vm.run_chunk chunk (Vm.make_global ()))
  | _ -> print_string usage; exit 1
