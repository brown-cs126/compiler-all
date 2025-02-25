(* L3 liveness analysis
 * Given a pseudo assembly code, liveness analysis
 * uses dataflow analysis to generate live-out set
 * for each instruction. This information will be 
 * used for reg_alloc_info.
 *
 * Notice that in liveness analysis, gen set of a 
 * statement is its rhs, and kill set is its defination.
 * Also, if a variable appears in both lhs and rhs,
 * then it is only stay in gen set and not in kill set.
 *
 * Author: Tianbo Hao <tianboh@alumni.cmu.edu>
 *)
open Core
module Dfana_info = Json_reader.Lab2_checkpoint
module Abs_asm = Abs_asm.Inst
module Temp = Var.Temp
module Register = Var.X86_reg
module Dfana = Flow.Dfana
module Label = Util.Label
module IG = Interference_graph

let print_line (line : Dfana_info.line) =
  printf "\n{gen: ";
  List.iter ~f:(fun x -> printf "%d " x) line.gen;
  printf "\nkill: ";
  List.iter ~f:(fun x -> printf "%d " x) line.kill;
  printf "\nsucc: ";
  List.iter ~f:(fun x -> printf "%d " x) line.succ;
  printf "\nis_label: %b" line.is_label;
  printf "\nline_number: %d}\n" line.line_number
;;

let print_df_info df_info = List.iter df_info ~f:(fun line -> print_line line)

(* tmp is from line_no to temporary *)
let print_liveout (liveout : (int list * int list * int) list) =
  List.iter liveout ~f:(fun line ->
      let _, out_l, lo = line in
      printf "line %d lo: " lo;
      List.iter out_l ~f:(fun x -> printf "%d " x);
      printf "\n")
;;

(* map is a hash table from label to line number *)
let rec gen_succ (inst_list : Abs_asm.instr list) (line_no : int) map =
  match inst_list with
  | [] -> map
  | h :: t ->
    (match h with
    | Abs_asm.Label l ->
      let map = Label.Map.set map ~key:l.label ~data:line_no in
      gen_succ t (line_no + 1) map
    | Jump _ | CJump _ | Ret _ | Mov _ | Binop _ | Assert _ | Fcall _ | Push _ | Pop _ ->
      gen_succ t (line_no + 1) map
    | Directive _ | Comment _ -> gen_succ t line_no map)
;;

let[@warning "-8"] _gen_df_info_helper (line_no : int) (line : Abs_asm.line) =
  let uses = line.uses in
  let defs = line.defines in
  let gen = Int.Set.of_list (Abs_asm.to_int_list uses) in
  let kill = Int.Set.of_list (Abs_asm.to_int_list defs) in
  let kill = Int.Set.diff kill gen in
  let succ = [ line_no + 1 ] in
  let is_label = false in
  ({ gen = Int.Set.to_list gen
   ; kill = Int.Set.to_list kill
   ; succ
   ; is_label
   ; line_number = line_no
   }
    : Dfana_info.line)
;;

let[@warning "-8"] _gen_df_info_cjump line_no (Abs_asm.CJump cjump) label_map =
  let uses = cjump.line.uses in
  let gen = Int.Set.of_list (Abs_asm.to_int_list uses) in
  let target_true_no = Label.Map.find_exn label_map cjump.target_true in
  let target_false_no = Label.Map.find_exn label_map cjump.target_false in
  ({ gen = Int.Set.to_list gen
   ; kill = []
   ; succ = [ target_true_no; target_false_no ]
   ; is_label = false
   ; line_number = line_no
   }
    : Dfana_info.line)
;;

let rec _gen_df_info_rev (inst_list : Abs_asm.instr list) line_no label_map res =
  match inst_list with
  | [] -> res
  | h :: t ->
    let line =
      match h with
      | Binop binop -> Some (_gen_df_info_helper line_no binop.line)
      | Mov mov -> Some (_gen_df_info_helper line_no mov.line)
      | Push push -> Some (_gen_df_info_helper line_no push.line)
      | Pop pop -> Some (_gen_df_info_helper line_no pop.line)
      | Assert asrt -> Some (_gen_df_info_helper line_no asrt.line)
      | Fcall fcall -> Some (_gen_df_info_helper line_no fcall.line)
      | Jump jp ->
        let target_line_no = Label.Map.find_exn label_map jp.target in
        Some
          ({ gen = []
           ; kill = []
           ; succ = [ target_line_no ]
           ; is_label = false
           ; line_number = line_no
           }
            : Dfana_info.line)
      | CJump cjp -> Some (_gen_df_info_cjump line_no (CJump cjp) label_map)
      | Ret ret ->
        Some
          ({ gen = Abs_asm.to_int_list ret.line.uses
           ; kill = Abs_asm.to_int_list ret.line.defines
           ; succ = []
           ; is_label = false
           ; line_number = line_no
           }
            : Dfana_info.line)
      | Label _ ->
        Some
          ({ gen = []
           ; kill = []
           ; succ = [ line_no + 1 ]
           ; is_label = true
           ; line_number = line_no
           }
            : Dfana_info.line)
      | Directive _ | Comment _ -> None
    in
    (match line with
    | None -> _gen_df_info_rev t line_no label_map res
    | Some line_s -> _gen_df_info_rev t (line_no + 1) label_map (line_s :: res))
;;

(* Generate information for each instruction. Info includes
 * gen, kill, succ, is_label, line_number *)
let gen_df_info (inst_list : Abs_asm.instr list) : Dfana_info.line list =
  let label_map = Label.Map.empty in
  let label_map = gen_succ inst_list 0 label_map in
  let res_rev = _gen_df_info_rev inst_list 0 label_map [] in
  List.rev res_rev
;;

let rec gen_temp (inst_list : Abs_asm.instr list) line_no map =
  match inst_list with
  | [] -> map
  | h :: t ->
    (match h with
    | Binop binop ->
      let map = Int.Map.set map ~key:line_no ~data:binop.dest in
      gen_temp t (line_no + 1) map
    | Mov mov ->
      let map = Int.Map.set map ~key:line_no ~data:mov.dest in
      gen_temp t (line_no + 1) map
    | Jump _ | CJump _ | Ret _ | Label _ | Assert _ | Fcall _ | Push _ | Pop _ ->
      gen_temp t (line_no + 1) map
    | Directive _ | Comment _ -> gen_temp t line_no map)
;;

(* Transform liveness information from int to temp. 
 * lo_int is the dataflow analysis result.
 * tmp_map is map from line_number to temporary/register *)
let rec trans_liveness (lo_int : (int list * int list * int) list) tmp_map res =
  match lo_int with
  | [] -> res
  | h :: t ->
    let _, out_int_list, line_no = h in
    let liveout =
      List.fold out_int_list ~init:IG.Vertex.Set.empty ~f:(fun acc x ->
          if x >= Register.num_reg
          then IG.Vertex.Set.add acc (IG.Vertex.T.Temp (Temp.of_int x))
          else IG.Vertex.Set.add acc (IG.Vertex.T.Reg (Register.idx_reg x)))
    in
    let res = Int.Map.set res ~key:line_no ~data:liveout in
    trans_liveness t tmp_map res
;;

let gen_liveness (inst_list : Abs_asm.instr list) =
  let df_info = gen_df_info inst_list in
  (* print_df_info df_info; *)
  let lo_int = Dfana.dfana df_info Args.Df_analysis.Backward_may in
  let tmp_map = gen_temp inst_list 0 Int.Map.empty in
  (* print_liveout lo_int; *)
  trans_liveness lo_int tmp_map Int.Map.empty
;;
