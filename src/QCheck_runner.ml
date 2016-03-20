(*
QCheck: Random testing for OCaml
Copyright (C) 2016  Vincent Hugot, Simon Cruanes

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Library General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Library General Public License for more details.

You should have received a copy of the GNU Lesser General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*)

open OUnit

let ps,pl = print_string,print_endline
let va = Printf.sprintf
let pf = Printf.printf

let separator1 = String.make 79 '\\'
let separator2 = String.make 79 '/'

let string_of_path path =
  let path = List.filter (function Label _ -> true | _ -> false) path in
  String.concat ">" (List.rev_map string_of_node path)

let result_path = function
    | RSuccess path
    | RError (path, _)
    | RFailure (path, _)
    | RSkip (path, _)
    | RTodo (path, _) -> path

let result_msg = function
    | RSuccess _ -> "Success"
    | RError (_, msg)
    | RFailure (_, msg)
    | RSkip (_, msg)
    | RTodo (_, msg) -> msg

let result_flavour = function
    | RError _ -> "Error"
    | RFailure _ -> "Failure"
    | RSuccess _ -> "Success"
    | RSkip _ -> "Skip"
    | RTodo _ -> "Todo"

let not_success = function RSuccess _ -> false | _ -> true

let print_result_list =
  List.iter (fun result -> pf "%s\n%s: %s\n\n%s\n%s\n"
    separator1 (result_flavour result)
    (string_of_path (result_path result))
    (result_msg result) separator2)

let seed = ref ~-1
let st = ref None

let set_seed_ s =
  seed := s;
  Printf.printf "random seed: %d\n%!" s;
  let state = Random.State.make [| s |] in
  st := Some state;
  state

let set_seed s = ignore (set_seed_ s)

let setup_random_state_ () =
  let s = if !seed = ~-1 then (
      Random.self_init ();  (* make new, truly random seed *)
      Random.int (1 lsl 29);
  ) else !seed in
  set_seed_ s

(* initialize random generator from seed (if any) *)
let random_state () = match !st with
  | Some st -> st
  | None -> setup_random_state_ ()

let verbose, set_verbose =
  let r = ref false in
  (fun () -> !r), (fun b -> r := b)

(* Function which runs the given function and returns the running time
   of the function, and the original result in a tuple *)
let time_fun f x y =
  let begin_time = Unix.gettimeofday () in
  let res = f x y in (* evaluate this first *)
  Unix.gettimeofday () -. begin_time, res

type cli_args = {
  cli_verbose : bool;
  cli_print_list : bool;
  cli_rand : Random.State.t;
}

let parse_cli argv =
  let print_list = ref false in
  let set_verbose () = Quickcheck.verbose := true in
  let set_list () = print_list := true in
  let options = Arg.align
    [ "-v", Arg.Unit set_verbose, " "
    ; "--verbose", Arg.Unit set_verbose, " enable verbose tests"
    ; "-l", Arg.Unit set_list, " "
    ; "--list", Arg.Unit set_list, " print list of tests (2 lines each)"
    ; "-s", Arg.Set_int seed, " "
    ; "--seed", Arg.Set_int seed, " set random seed (to repeat tests)"
    ] in
  Arg.parse_argv argv options (fun _ ->()) "run qtest suite";
  let cli_rand = setup_random_state_ () in
  { cli_verbose=verbose(); cli_rand; cli_print_list= !print_list; }

let run ?(argv=Sys.argv) test =
  let cli_args = parse_cli argv in
  let _counter = ref (0,0,0) in (* Success, Failure, Other *)
  let total_tests = test_case_count test in
  let update = function
    | RSuccess _ -> let (s,f,o) = !_counter in _counter := (succ s,f,o)
    | RFailure _ -> let (s,f,o) = !_counter in _counter := (s,succ f,o)
    | _ -> let (s,f,o) = !_counter in _counter := (s,f, succ o)
  in
  (* time each test *)
  let start = ref 0. and stop = ref 0. in
  (* display test as it starts and ends *)
  let display_test ?(ended=false) p  =
    let (s,f,o) = !_counter in
    let cartouche = va " [%d%s%s / %d] " s
      (if f=0 then "" else va "+%d" f)
      (if o=0 then "" else va " %d!" o) total_tests
    and path = string_of_path p in
    let end_marker =
      if cli_args.cli_print_list then (
        (* print a single line *)
        if ended then va " (after %.2fs)\n" (!stop -. !start) else "\n"
      ) else (
        ps "\r";
        if ended then " *" else ""
      )
    in
    let line = cartouche ^ path ^ end_marker in
    let remaining = 79 - String.length line in
    let cover = if remaining > 0 && not cli_args.cli_print_list
      then String.make remaining ' ' else "" in
    pf "%s%s%!" line cover;
  in
  let hdl_event = function
    | EStart p -> start := Unix.gettimeofday(); display_test p
    | EEnd p  -> stop := Unix.gettimeofday(); display_test p ~ended:true
    | EResult result -> update result
  in
  ps "Running tests...";
  let running_time, results = time_fun perform_test hdl_event test in
  let (_s, f, o) = !_counter in
  let failures = List.filter not_success results in
  (*  assert (List.length failures = f);*)
  ps "\r";
  print_result_list failures;
  assert (List.length results = total_tests);
  pf "Ran: %d tests in: %.2f seconds.%s\n"
    total_tests running_time (String.make 40 ' ');
  if failures = [] then pl "SUCCESS";
  if o <> 0 then pl "WARNING! SOME TESTS ARE NEITHER SUCCESSES NOR FAILURES!";
  (* create a meaningful return code for the process running the tests *)
  match f, o with
    | 0, 0 -> 0
    | _ -> 1

(* TAP-compatible test runner, in case we want to use a test harness *)

let run_tap test =
  let test_number = ref 0 in
  let handle_event = function
    | EStart _ | EEnd _ -> incr test_number
    | EResult (RSuccess p) ->
      pf "ok %d - %s\n%!" !test_number (string_of_path p)
    | EResult (RFailure (p,m)) ->
      pf "not ok %d - %s # %s\n%!" !test_number (string_of_path p) m
    | EResult (RError (p,m)) ->
      pf "not ok %d - %s # ERROR:%s\n%!" !test_number (string_of_path p) m
    | EResult (RSkip (p,m)) ->
      pf "not ok %d - %s # skip %s\n%!" !test_number (string_of_path p) m
    | EResult (RTodo (p,m)) ->
      pf "not ok %d - %s # todo %s\n%!" !test_number (string_of_path p) m
  in
  let total_tests = test_case_count test in
  pf "TAP version 13\n1..%d\n" total_tests;
  perform_test handle_event test

let next_name_ =
  let i = ref 0 in
  fun () ->
    let name = "<anon prop> " ^ (string_of_int !i) in
    incr i;
    name

(* main callback for individual tests
   @param verbose if true, print statistics and details
   @param print_res if true, print the result on [out] *)
let callback ~verbose ~print_res ~out name cell result =
  let module R = QCheck.TestResult in
  let module T = QCheck.Test in
  let arb = T.get_arbitrary cell in
  if verbose then (
    Printf.fprintf out "\rlaw %s: %d relevant cases (%d total)\n"
      name result.R.count result.R.count_gen;
    match arb.QCheck.collect with
    | None -> ()
    | Some _ ->
        let (lazy tbl) = result.R.collect_tbl in
        Hashtbl.iter
          (fun case num -> Printf.fprintf out "\r  %s: %d cases\n" case num)
          tbl
  );
  if print_res then (
    (* even if [not verbose], print errors *)
    match result.R.state with
      | R.Success -> ()
      | R.Failed l ->
          Printf.fprintf out "\r  %s\n" (T.print_fail arb name l)
      | R.Error (i,e) ->
          Printf.fprintf out "\r  %s\n" (T.print_error arb name (i,e))
  );
  flush out

(* to convert a test to a [OUnit.test], we register a callback that will
   possibly print errors and counter-examples *)
let to_ounit_test_cell ?(verbose=verbose()) ?(rand=random_state()) cell =
  let module T = QCheck.Test in
  let name = match T.get_name cell with
    | None ->
        let n = next_name_ () in
        T.set_name cell n;
        n
    | Some m -> m
  in
  let run () =
    T.check_cell_exn cell
      ~rand ~call:(callback ~verbose ~print_res:verbose ~out:stdout);
    true
  in
  name >:: (fun _ -> assert_bool name (run ()))

let to_ounit_test ?verbose ?rand (QCheck.Test.Test c) =
  to_ounit_test_cell ?verbose ?rand c

let (>:::) name l =
  name >::: (List.map (fun t -> to_ounit_test t) l)

let run_tests ?(verbose=verbose()) ?(out=stdout) ?(rand=random_state()) l =
  let module T = QCheck.Test in
  let module R = QCheck.TestResult in
  let ok = ref true in
  List.iter
    (fun (T.Test cell) ->
      let res =
        T.check_cell cell ~call:(callback ~out ~print_res:true ~verbose) ~rand
      in
      match res.R.state with
      | R.Success -> ()
      | R.Failed _ | R.Error _ -> ok := false)
    l;
  if !ok then 0 else 1

let run_tests_main ?(argv=Sys.argv) l =
  let cli_args = parse_cli argv in
  exit
    (run_tests ~verbose:cli_args.cli_verbose ~out:stdout ~rand:cli_args.cli_rand l)
