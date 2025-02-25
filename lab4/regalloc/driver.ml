open Core

(*
 * This file contains necessary functions to allocate registers
 * based on input file described as type program in Lab1_checkpoint.
 *
 * We considered x86 conventions during register allocation. 
 * They are of register type in as vertex.
 * See https://www.cs.cmu.edu/~janh/courses/411/17/lec/03-regalloc.pdf Section 7 for details.
 * This is automatically done during Convention.X86.gen because it provide def use info.
 *
 * The basic allocation procedure follows:
 *   1) Build interference graph. We build edge between line.defines and line.live_out.
 *     Edges are also created between defines in the same instruction.
 *     For special instructions like mul, div, mod, shift, we follow the same scheme because
 *     special registers are already in defines during Convention.X86.gen.
 *     Time complexity: O(v + e)
 *   2) Use maximum cardinality search to build SEO
 *     Theoratically, We initialize every vertex with weight 0. Then, each time
 *     we start from a vertex u with maximum weight and update its neighbors weight by one.
 *     Then we record vertex u and delete from graph, and keep doing so until no vertex left on graph.
 *     Notice temporaries in interference graph is pure SSA.
 *     So we can apply maximum cardinality to find optimal register allocation policy.
 *     Time complexity for SEO: O(v + e)
 *   3) Greedy coloring based on SEO
 *     Greedy assign registers in SEO order. The rule is generate register with minimum index which
 *     is greater than its allocated neighbors.
 *     Time complexity for coloring: O(v + e)
 *)
module Temp = Var.Temp
module Size = Var.Size
module Register = Var.X86_reg.Logic
module Spill = Var.X86_reg.Spill
module Reg_info = Program
module Abs_asm = Abs_asm.Inst
module IG = Interference_graph

type dest =
  | Reg of Register.t
  | Spill of Spill.t

let threshold = 2000
let eax = Register.RAX
let ecx = Register.RCX
let edx = Register.RDX

module Print = struct
  open Printf

  (* print adjacency list (interference graph) *)
  let print_adj adj =
    printf "\nprint adj\n";
    let keys = IG.Vertex.Map.keys adj in
    let sorted_keys = List.sort keys ~compare:IG.Vertex.compare in
    let () =
      List.iter sorted_keys ~f:(fun key ->
          let s = IG.Vertex.Map.find_exn adj key in
          let l = List.sort (IG.Vertex.Set.to_list s) ~compare:IG.Vertex.compare in
          printf "From %s to\t" (IG.Print.pp_vertex key);
          List.iter l ~f:(fun x -> printf "%s " (IG.Print.pp_vertex x));
          printf "\n")
    in
    printf "\n\n"
  ;;

  let print_vertex_to_dest (color : dest IG.Vertex.Map.t) =
    let () = printf "\n\n==========\nVertex to register\n" in
    let sorted_keys = List.sort (IG.Vertex.Map.keys color) ~compare:IG.Vertex.compare in
    List.iter sorted_keys ~f:(fun k ->
        let t = IG.Print.pp_vertex k in
        let r =
          match IG.Vertex.Map.find_exn color k with
          | Reg r -> Register.pp r
          | Spill s -> Spill.pp s
        in
        printf "%s -> %s\n%!" t r)
  ;;
end

module Helper = struct
  (* Build edge between vertices and vertex *)
  let build_vtx_vtxs adj vertex vertices =
    let s_vertex = IG.Vertex.Set.of_list [ vertex ] in
    let s_vertex_nbr =
      match IG.Vertex.Map.find adj vertex with
      | None -> IG.Vertex.Set.empty
      | Some s -> s
    in
    let s_vertex_nbr_union = IG.Vertex.Set.union s_vertex_nbr vertices in
    let adj = IG.Vertex.Map.set adj ~key:vertex ~data:s_vertex_nbr_union in
    IG.Vertex.Set.fold_right vertices ~init:adj ~f:(fun v adj ->
        let s_vertices =
          match IG.Vertex.Map.find adj v with
          | None -> IG.Vertex.Set.empty
          | Some s -> s
        in
        let s_res = IG.Vertex.Set.union s_vertices s_vertex in
        IG.Vertex.Map.set adj ~key:v ~data:s_res)
  ;;

  (* Build interference graph based on def and (live_out Union uses).
   * The insight here is we cannot allocate/assign register for def with the same register as
   * registers allocated for live_out temps.
   * Theoretically, we don't need to build edge between def and uses. But In order to 
   * make x86 assembly code generation easier, we don't allow uses and def to be assigned
   * to the same register. This can be more flexible for x86 assembly code generation.
   *)
  let rec build_graph reginfo_instr adj =
    match reginfo_instr with
    | [] -> adj
    | h :: t ->
      let reginfo, _ = h in
      (* Reg_info.print_line reginfo; *)
      let defs = Reg_info.get_defs reginfo in
      let adj =
        IG.Vertex.Set.fold defs ~init:adj ~f:(fun acc_adj def ->
            (* build edges between defs *)
            let defs' = IG.Vertex.Set.diff defs (IG.Vertex.Set.of_list [ def ]) in
            let s_def_nbr =
              match IG.Vertex.Map.find adj def with
              | Some s -> IG.Vertex.Set.union s defs'
              | None -> defs'
            in
            let s_lo = reginfo.live_out in
            let s_u = IG.Vertex.Set.union s_def_nbr s_lo in
            build_vtx_vtxs acc_adj def s_u)
      in
      build_graph t adj
  ;;

  (* Table store info from vertex to number which will be used in seo. *)
  let gen_vertex_table prog =
    let rec helper prog hash =
      match prog with
      | [] -> hash
      | h :: t ->
        let defs = Reg_info.get_defs h in
        let uses = Reg_info.get_uses h in
        let vs = IG.Vertex.Set.union defs uses in
        let hash =
          IG.Vertex.Set.fold vs ~init:hash ~f:(fun acc_hash def_ ->
              let acc_hash = IG.Vertex.Map.set acc_hash ~key:def_ ~data:0 in
              acc_hash)
        in
        helper t hash
    in
    helper prog IG.Vertex.Map.empty
  ;;
end

module Lazy = struct
  type reg = Register.t

  let threshold = 2000
  let eax = Register.RAX
  let ecx = Register.RCX
  let edx = Register.RDX

  let trans_operand (operand : Abs_asm.Sop.t) =
    match operand.data with
    | Abs_asm.Op.Temp t -> IG.Vertex.Set.of_list [ IG.Vertex.T.Temp t ]
    | Abs_asm.Op.Imm _ | Abs_asm.Op.Above_frame _ -> IG.Vertex.Set.empty
    | Abs_asm.Op.Reg r -> IG.Vertex.Set.of_list [ IG.Vertex.T.Reg r ]
  ;;

  let rec collect_vertex (prog : Abs_asm.instr list) res =
    match prog with
    | [] -> res
    | h :: t ->
      (match h with
      | Binop binop ->
        let res = IG.Vertex.Set.union res (trans_operand binop.dest) in
        let res = IG.Vertex.Set.union res (trans_operand binop.lhs) in
        let res = IG.Vertex.Set.union res (trans_operand binop.rhs) in
        collect_vertex t res
      | Mov mov ->
        let res = IG.Vertex.Set.union res (trans_operand mov.dest) in
        let res = IG.Vertex.Set.union res (trans_operand mov.src) in
        collect_vertex t res
      | Cast cast ->
        let dest = Abs_asm.St.to_Sop cast.dest in
        let src = Abs_asm.St.to_Sop cast.src in
        let res = IG.Vertex.Set.union res (trans_operand dest) in
        let res = IG.Vertex.Set.union res (trans_operand src) in
        collect_vertex t res
      | CJump cjp ->
        let res = IG.Vertex.Set.union res (trans_operand cjp.lhs) in
        let res = IG.Vertex.Set.union res (trans_operand cjp.rhs) in
        collect_vertex t res
      | Ret _ -> collect_vertex t res
      | Fcall fcall ->
        let res =
          List.fold fcall.args ~init:res ~f:(fun acc arg ->
              IG.Vertex.Set.union acc (trans_operand arg))
        in
        collect_vertex t res
      | Push push ->
        let res = IG.Vertex.Set.union res (trans_operand push.var) in
        collect_vertex t res
      | Pop pop ->
        let res = IG.Vertex.Set.union res (trans_operand pop.var) in
        collect_vertex t res
      | Load load ->
        let dest = Abs_asm.St.to_Sop load.dest in
        let res = IG.Vertex.Set.union res (trans_operand dest) in
        collect_vertex t res
      | Store store ->
        let res = IG.Vertex.Set.union res (trans_operand store.src) in
        collect_vertex t res
      | Jump _ | Label _ | Directive _ | Comment _ -> collect_vertex t res)
  ;;

  let gen_result_dummy vertex_set =
    let cnt = ref 16 in
    let cache = ref Int.Map.empty in
    let vertex_list = IG.Vertex.Set.to_list vertex_set in
    List.map vertex_list ~f:(fun vtx ->
        let dest =
          match vtx with
          | IG.Vertex.T.Reg r -> Reg r
          | IG.Vertex.T.Temp t ->
            if Int.Map.mem !cache t.id
            then (
              let id = Int.Map.find_exn !cache t.id in
              Spill (Spill.of_int id))
            else (
              let id = !cnt in
              cache := Int.Map.set !cache ~key:t.id ~data:!cnt;
              cnt := !cnt + 1;
              Spill (Spill.of_int id))
        in
        match dest with
        | Spill _ -> Some (vtx, dest)
        | Reg _ -> None)
  ;;
end

let rec _seo_rev adj vertex_table seq =
  match IG.Vertex.Map.is_empty vertex_table with
  | true -> seq
  | false ->
    let u, _ =
      match
        IG.Vertex.Map.fold vertex_table ~init:None ~f:(fun ~key ~data accu ->
            match accu with
            | None -> Some (key, data)
            | Some (_, data') -> if data' > data then accu else Some (key, data))
      with
      | None -> failwith "empty vertex_table"
      | Some s -> s
    in
    let seq_new = u :: seq in
    let nbr = IG.Vertex.Map.find_exn adj u in
    let nbr = IG.Vertex.Set.remove nbr u in
    let vertex_table =
      IG.Vertex.Set.fold_right nbr ~init:vertex_table ~f:(fun x acc ->
          match IG.Vertex.Map.find vertex_table x with
          | None -> acc
          | Some v ->
            let order = v + 1 in
            IG.Vertex.Map.set vertex_table ~key:x ~data:order)
    in
    let vertex_table = IG.Vertex.Map.remove vertex_table u in
    _seo_rev adj vertex_table seq_new
;;

let seo adj prog =
  let vertex_table = Helper.gen_vertex_table prog in
  let seo_rev = _seo_rev adj vertex_table [] in
  List.rev seo_rev
;;

(* find minimum available register with neighbor nbr *)
let find_min_available (nbr : Int.Set.t) (black_set : Int.Set.t) : int =
  let rec helper (idx : int) =
    if Register.special_use' idx || Set.mem black_set idx
    then helper (idx + 1)
    else if Set.mem nbr idx
    then helper (idx + 1)
    else idx
  in
  helper 0
;;

(* Allocate register for vertex. Neighbors may be of register or 
 * temporary. If neighbor is register, put this register to blacklist
 * so we will not assign this register to the current vertex.
 * vertex_to_dest is a hashtable from vertex to registers.
 * nbr is the neighbor of vertex
 * 
 * In a word, the chosen register whould satisfy below requirement
 * 1) Not the same as hard registers of its neighbor. For example,
 * if t is connected to rax, it will not be assigned as rax.
 * 2) Minimum available registers among its temporary neighbors.
 *)
let alloc (nbr : IG.Vertex.Set.t) (vertex_to_dest : dest IG.Vertex.Map.t) : dest =
  (* If a temporary is connected to a register, 
   * we cannot assign this register to it. *)
  let nbr_black_list =
    IG.Vertex.Set.fold nbr ~init:[] ~f:(fun acc u ->
        match u with
        | IG.Vertex.T.Reg r -> Register.get_idx r :: acc
        | IG.Vertex.T.Temp _ -> acc)
  in
  (* Keep track of assigned registers for neighbor temporaries *)
  let nbr_int_l =
    IG.Vertex.Set.fold nbr ~init:[] ~f:(fun acc u ->
        match IG.Vertex.Map.find vertex_to_dest u with
        | None -> acc
        | Some u' ->
          (match u' with
          | Reg r -> Register.get_idx r :: acc
          | Spill m -> Spill.get_idx16 m :: acc))
  in
  let nbr_int_s = Int.Set.of_list nbr_int_l in
  let black_set = Int.Set.of_list nbr_black_list in
  let r = find_min_available nbr_int_s black_set in
  if r < Register.num_reg then Reg (Register.idx_reg r) else Spill (Spill.of_int r)
;;

(* Infinite registers to allocate during greedy coloring. *)
let rec greedy seq adj vertex_to_dest =
  match seq with
  | [] -> vertex_to_dest
  | h :: t ->
    (match h with
    | IG.Vertex.T.Reg _ -> greedy t adj vertex_to_dest
    | IG.Vertex.T.Temp temp ->
      let nbr = IG.Vertex.Map.find_exn adj h in
      let dest = alloc nbr vertex_to_dest in
      (* let () =
        match dest with
        | Reg r ->
          printf "alloc %s for %s\n" (Var.X86_reg.Logic.ppr) (Temp.name temp)
        | Spill s -> printf "alloc %s for %s\n" (Spill.pp s) (Temp.name temp)
      in *)
      let vertex_to_dest =
        IG.Vertex.Map.set vertex_to_dest ~key:(IG.Vertex.T.Temp temp) ~data:dest
      in
      greedy t adj vertex_to_dest)
;;

let rec gen_result (color : dest IG.Vertex.Map.t) prog =
  match prog with
  | [] -> []
  | h :: t ->
    let defs = Reg_info.get_defs h in
    let uses = Reg_info.get_uses h in
    let vs = IG.Vertex.Set.union defs uses in
    let assign_l =
      IG.Vertex.Set.fold vs ~init:[] ~f:(fun acc v ->
          match v with
          | IG.Vertex.T.Temp _ ->
            let dest = IG.Vertex.Map.find color v in
            let tk =
              match dest with
              | None -> None
              | Some dest' -> Some (v, dest')
            in
            tk :: acc
          | IG.Vertex.T.Reg _ -> None :: acc)
    in
    assign_l @ gen_result color t
;;

let regalloc (fdefn : Abs_asm.fdefn) : (IG.Vertex.t * dest) option list =
  let vertex_set = Lazy.collect_vertex fdefn.body IG.Vertex.Set.empty in
  if IG.Vertex.Set.length vertex_set > threshold
  then Lazy.gen_result_dummy vertex_set
  else (
    let reginfo_instrs = Program.gen_regalloc_info fdefn.body in
    let adj = Helper.build_graph reginfo_instrs IG.Vertex.Map.empty in
    let prog =
      List.fold_left reginfo_instrs ~init:[] ~f:(fun acc line ->
          let reginfo, _ = line in
          reginfo :: acc)
    in
    let seq = seo adj prog in
    let vertex_to_dest = IG.Vertex.Map.empty in
    let color = greedy seq adj vertex_to_dest in
    (* Print.print_adj adj;
    printf "SEO order\n";
    let seq_l = List.map seq ~f:(fun x -> IG.Print.pp_vertex x) in
    List.iter ~f:(printf "%s ") seq_l;
    Print.print_vertex_to_dest color;
    printf "\n%!"; *)
    gen_result color prog)
;;
