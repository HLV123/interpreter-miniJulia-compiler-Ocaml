(* MiniJulia Web Server — pure OCaml, no external HTTP deps *)
open Unix

let port = 7777
let web_dir = "/workspace/web"

(* ── HTTP helpers ── *)
let read_request fd =
  let buf = Bytes.create 4096 in
  let n   = read fd buf 0 4096 in
  Bytes.sub_string buf 0 n

let send_response fd status content_type body =
  let header = Printf.sprintf
    "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, GET, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
    status content_type (String.length body) in
  let msg = header ^ body in
  let _ = write_substring fd msg 0 (String.length msg) in
  ()

let read_file path =
  try
    let ic = open_in path in
    let n  = in_channel_length ic in
    let s  = Bytes.create n in
    really_input ic s 0 n;
    close_in ic;
    Some (Bytes.to_string s)
  with _ -> None

(* ── URL decode ── *)
let url_decode s =
  let n   = String.length s in
  let buf = Buffer.create n in
  let i   = ref 0 in
  while !i < n do
    match s.[!i] with
    | '%' when !i + 2 < n ->
        let hex = String.sub s (!i + 1) 2 in
        (try
          let c = Char.chr (int_of_string ("0x" ^ hex)) in
          Buffer.add_char buf c; i := !i + 3
        with _ -> Buffer.add_char buf '%'; incr i)
    | '+' -> Buffer.add_char buf ' '; incr i
    | c   -> Buffer.add_char buf c; incr i
  done;
  Buffer.contents buf

(* ── JSON helpers ── *)
let json_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (function
    | '"'  -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c    -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(* ── Parse HTTP request ── *)
type request = {
  meth    : string;
  path    : string;
  body    : string;
}

let parse_request raw =
  let lines = String.split_on_char '\n' raw in
  let first = match lines with l :: _ -> String.trim l | [] -> "" in
  let parts = String.split_on_char ' ' first in
  let meth  = (match parts with m :: _ -> m | _ -> "GET") in
  let path  = (match parts with _ :: p :: _ -> p | _ -> "/") in
  (* Extract body after \r\n\r\n *)
  let sep = "\r\n\r\n" in
  let body =
    match String.split_on_char '\r' raw with
    | _ ->
      let idx = ref (-1) in
      (try
        for i = 0 to String.length raw - 4 do
          if String.sub raw i 4 = sep then idx := i
        done
      with _ -> ());
      if !idx >= 0 then
        String.sub raw (!idx + 4) (String.length raw - !idx - 4)
      else ""
  in
  { meth; path; body }

(* ── Extract JSON field ── *)
let extract_json_field json field =
  let key = "\"" ^ field ^ "\"" in
  match String.split_on_char '"' json with
  | _ ->
    (* Simple: find "field":"value" pattern *)
    let prefix = key ^ ":" in
    (match String.split_on_char '"' json with
     | parts ->
       let rec find = function
         | [] -> None
         | a :: b :: rest ->
             let a_trimmed = String.trim (String.concat "" (String.split_on_char ' ' a)) in
             if String.length a_trimmed >= String.length prefix &&
                String.sub a_trimmed
                  (String.length a_trimmed - String.length prefix)
                  (String.length prefix) = prefix
             then Some b
             else find (b :: rest)
         | [_] -> None
       in
       find parts)

(* ── Run MiniJulia code ── *)
let run_code code =
  (* Write to temp file *)
  let tmp = "/tmp/repl_input.jl" in
  let out = "/tmp/repl_output.txt" in
  let err = "/tmp/repl_error.txt" in
  let oc = open_out tmp in
  output_string oc code;
  close_out oc;
  let cmd = Printf.sprintf
    "/workspace/_build/default/bin/main.exe %s > %s 2> %s"
    tmp out err in
  let ret = Sys.command cmd in
  let stdout = (match read_file out with Some s -> s | None -> "") in
  let stderr = (match read_file err with Some s -> s | None -> "") in
  let output = stdout ^
    (if stderr <> "" then "\n[stderr]: " ^ stderr else "") in
  (ret, output)

(* ── Content type by extension ── *)
let content_type_of path =
  if String.length path > 5 &&
     String.sub path (String.length path - 5) 5 = ".html"
  then "text/html; charset=utf-8"
  else if String.length path > 3 &&
          String.sub path (String.length path - 3) 3 = ".js"
  then "application/javascript"
  else if String.length path > 4 &&
          String.sub path (String.length path - 4) 4 = ".css"
  then "text/css"
  else "text/plain"

(* ── Handle request ── *)
let handle fd req =
  match req.meth, req.path with
  | "OPTIONS", _ ->
      send_response fd "200 OK" "text/plain" ""

  | ("GET" | "HEAD"), "/" ->
      let path = web_dir ^ "/index.html" in
      (match read_file path with
       | Some content ->
           send_response fd "200 OK" "text/html; charset=utf-8" content
       | None ->
           send_response fd "404 Not Found" "text/plain" "index.html not found")

  | ("GET" | "HEAD"), path ->
      let file_path = web_dir ^ path in
      (match read_file file_path with
       | Some content ->
           send_response fd "200 OK" (content_type_of path) content
       | None ->
           send_response fd "404 Not Found" "text/plain" ("Not found: " ^ path))

  | "POST", "/run" ->
      (* Extract code from JSON body *)
      let code =
        match extract_json_field req.body "code" with
        | Some c -> url_decode c
        | None   -> req.body
      in
      (* Actually parse JSON string properly *)
      let code =
        (* body is: {"code": "..."} — extract between first and last quote pair *)
        let b = req.body in
        let key = "\"code\":" in
        (try
          let start = ref 0 in
          for i = 0 to String.length b - String.length key do
            if String.sub b i (String.length key) = key then
              start := i + String.length key
          done;
          (* find opening quote *)
          let s = ref !start in
          while !s < String.length b && b.[!s] <> '"' do incr s done;
          incr s; (* skip " *)
          (* read until unescaped " *)
          let buf = Buffer.create 256 in
          let i = ref !s in
          while !i < String.length b && b.[!i] <> '"' do
            if b.[!i] = '\\' && !i + 1 < String.length b then begin
              (match b.[!i + 1] with
               | 'n'  -> Buffer.add_char buf '\n'
               | 't'  -> Buffer.add_char buf '\t'
               | '"'  -> Buffer.add_char buf '"'
               | '\\' -> Buffer.add_char buf '\\'
               | 'r'  -> Buffer.add_char buf '\r'
               | c    -> Buffer.add_char buf '\\'; Buffer.add_char buf c);
              i := !i + 2
            end else begin
              Buffer.add_char buf b.[!i]; incr i
            end
          done;
          Buffer.contents buf
        with _ -> code)
      in
      let (ret, output) = run_code code in
      let status = if ret = 0 then "ok" else "error" in
      let json = Printf.sprintf
        "{\"status\":\"%s\",\"output\":\"%s\"}"
        status (json_escape output) in
      send_response fd "200 OK" "application/json" json

  | _ ->
      send_response fd "405 Method Not Allowed" "text/plain" "Method not allowed"

(* ── Main server loop ── *)
let () =
  let sock = socket PF_INET SOCK_STREAM 0 in
  setsockopt sock SO_REUSEADDR true;
  bind sock (ADDR_INET (inet_addr_any, port));
  listen sock 10;
  Printf.printf "MiniJulia IDE server running on http://localhost:%d\n%!" port;
  Printf.printf "Open your browser and go to: http://localhost:%d\n%!" port;
  while true do
    let (client_fd, _) = accept sock in
    (* Fork to handle concurrently — simple approach *)
    (try
      let raw = read_request client_fd in
      if String.length raw > 0 then begin
        let req = parse_request raw in
        handle client_fd req
      end
    with _ -> ());
    close client_fd
  done
