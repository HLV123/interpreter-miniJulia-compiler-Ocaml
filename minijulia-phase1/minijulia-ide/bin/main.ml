let usage = {|
MiniJulia 0.1 — Julia-like interpreter

Usage:
  minijulia                  Start REPL
  minijulia <file.jl>        Run a file
  minijulia -e "code"        Run inline code
  minijulia --help           Show this message
|}

let () =
  match Array.to_list Sys.argv |> List.tl with
  | [] ->
      Interpreter.repl ()
  | ["--help"] | ["-h"] ->
      print_string usage
  | ["-e"; code] ->
      let g = Interpreter.make_global () in
      let prog = Parser.parse code in
      Interpreter.exec_stmts g prog
  | [file] ->
      Interpreter.run_file file
  | _ ->
      print_string usage; exit 1
