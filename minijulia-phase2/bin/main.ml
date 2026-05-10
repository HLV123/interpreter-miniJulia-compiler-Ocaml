let usage = {|
MiniJulia 0.2 - Phase 2: Bytecode VM

Usage:
  minijulia <file.jl>        Run with VM (default)
  minijulia -i <file.jl>     Run with interpreter (phase 1)
  minijulia compile <f.jl>   Compile to bytecode (.mjc)
  minijulia run <f.mjc>      Run precompiled bytecode
  minijulia disasm <f.jl>    Show disassembly
  minijulia bench <f.jl>     Benchmark interpreter vs VM
  minijulia -e "code"        Run inline code
|}

let read_file path =
  let ic = open_in path in
  let n  = in_channel_length ic in
  let s  = Bytes.create n in
  really_input ic s 0 n; close_in ic;
  Bytes.to_string s

let () =
  match Array.to_list Sys.argv |> List.tl with
  | [] -> Interpreter.repl ()
  | ["--help"] | ["-h"] -> print_string usage
  | ["-e"; code] -> let prog = Parser.parse code in let chunk = Compiler.compile_program prog in ignore (Vm.run_chunk chunk (Vm.make_global ()))
  | ["compile"; file] ->
      let chunk = Compiler.compile_program ~source:file (Parser.parse (read_file file)) in
      let out   = Filename.remove_extension file ^ ".mjc" in
      Vm.save_bytecode chunk out
  | ["run"; file] ->
      let chunk = Vm.load_bytecode file in
      ignore (Vm.run_chunk chunk (Vm.make_global ()))
  | ["disasm"; file] ->
      let chunk = Compiler.compile_program ~source:file (Parser.parse (read_file file)) in
      Bytecode.disassemble chunk
  | ["bench"; file] ->
      let src = read_file file in
      Printf.printf "Benchmark: %s\n\n" file;
      let t0 = Unix.gettimeofday () in
      let g  = Interpreter.make_global () in
      Interpreter.exec_stmts g (Parser.parse src);
      let t1 = Unix.gettimeofday () in
      Printf.printf "Interpreter: %.4fs\n" (t1 -. t0);
      let t2    = Unix.gettimeofday () in
      let chunk = Compiler.compile_program ~source:file (Parser.parse src) in
      ignore (Vm.run_chunk chunk (Vm.make_global ()));
      let t3 = Unix.gettimeofday () in
      Printf.printf "Bytecode VM: %.4fs\n" (t3 -. t2);
      if (t3 -. t2) > 0.0 then
        Printf.printf "Speedup:     %.1fx\n" ((t1 -. t0) /. (t3 -. t2))
  | ["-i"; file] -> Interpreter.run_file file
  | [file] when Filename.check_suffix file ".mjc" ->
      ignore (Vm.run_chunk (Vm.load_bytecode file) (Vm.make_global ()))
  | [file] -> let src = read_file file in let prog = Parser.parse src in let chunk = Compiler.compile_program ~source:file prog in ignore (Vm.run_chunk chunk (Vm.make_global ()))
  | _ -> print_string usage; exit 1
