(* L2 Compiler
 * Assembly Code Generator for FAKE assembly
 * Author: Alex Vaynberg <alv@andrew.cmu.edu>
 * Based on code by: Kaustuv Chaudhuri <kaustuv+@cs.cmu.edu>
 * Modified: Frank Pfenning <fp@cs.cmu.edu>
 * Converted to OCaml by Michael Duggan <md5i@cs.cmu.edu>
 * Modified: Alice Rao <alrao@andrew.cmu.edu>
 * Modified: Nick Roberts <nroberts@alumni.cmu.edu>
 *   - Use a linear, not quadratic, algorithm.
 *
 * Implements a "convenient munch" algorithm
 * We provide 3 address pseudo and 2 address pseudo based on x86 architecture.
 * the way to convert from 3 address to 2 address is to use same operand for
 * Destination and first operand for binary operation. This makes sense because
 * Each binary op will copy the operand and then calculate. The copied operand will
 * never be used again after calculation. So we can safely store the result to the
 * operand.
 * Notice that for [a <- b + c, d <- b + c ] will not reuse temporary in b and c 
 * in the second execution. The assembly looks like
 * t1 <- some_value for b
 * t2 <- some_value for c
 * t3 <- t1
 * t4 <- t2
 * t5 <- t3 + t4
 * t6 <- t1
 * t7 <- t2
 * t8 <- t6 + t7
 * Therefore, we can reuse t3 as destination of t3 + t4 for x86 add inplace mechanism.
 *)

open Core
module T = Parser.Tree
module AS = Inst.Pseudo
module AS_x86 = Inst.X86
module Reg_info = Json_reader.Lab1_checkpoint
module Temp = Var.Temp
module Register = Var.X86_reg
module Memory = Var.Memory
open Var.Layout

let munch_op = function
  | T.Plus -> AS.Plus
  | T.Minus -> AS.Minus
  | T.Times -> AS.Times
  | T.Divided_by -> AS.Divided_by
  | T.Modulo -> AS.Modulo
  | T.And -> AS.And
  | T.Or -> AS.Or
  | T.Hat -> AS.Hat
  | T.Right_shift -> AS.Right_shift
  | T.Left_shift -> AS.Left_shift
  | T.Equal_eq -> AS.Equal_eq
  | T.Greater -> AS.Greater
  | T.Greater_eq -> AS.Greater_eq
  | T.Less -> AS.Less
  | T.Less_eq -> AS.Less_eq
  | T.Not_eq -> AS.Not_eq
;;

module Pseudo = struct
  (* munch_exp_acc dest exp rev_acc
   *
   * Suppose we have the statement:
   *   dest <-- exp
   *
   * If the codegened statements for this are:
   *   s1; s2; s3; s4;
   *
   * Then this function returns the result:
   *   s4 :: s3 :: s2 :: s1 :: rev_acc
   *
   * I.e., rev_acc is an accumulator argument where the codegen'ed
   * statements are built in reverse. This allows us to create the
   * statements in linear time rather than quadratic time (for highly
   * nested expressions).
   *)
  let rec munch_exp_acc (dest : AS.operand) (exp : T.exp) (rev_acc : AS.instr list)
      : AS.instr list
    =
    match exp with
    | T.Const i -> AS.Mov { dest; src = AS.Imm i } :: rev_acc
    | T.Temp t -> AS.Mov { dest; src = AS.Temp t } :: rev_acc
    | T.Binop binop -> munch_binop_acc dest (binop.op, binop.lhs, binop.rhs) rev_acc
    | T.Sexp sexp ->
      let stm = munch_stm sexp.stm in
      let stm_rev = List.rev stm in
      let ret = stm_rev @ rev_acc in
      (* Notice that sexp does not return any thing,
       * it is only used for side effect.
       * So we create a temporary as dest, but do not
       * use it in the above level. *)
      let t = AS.Temp (Temp.create ()) in
      munch_exp_acc t sexp.exp ret

  (* munch_binop_acc dest (binop, e1, e2) rev_acc
   *
   * generates instructions to achieve dest <- e1 binop e2
   *
   * Much like munch_exp, this returns the result of appending the
   * instructions in reverse to the accumulator argument, rev_acc.
   *)
  and munch_binop_acc
      (dest : AS.operand)
      ((binop, e1, e2) : T.binop * T.exp * T.exp)
      (rev_acc : AS.instr list)
      : AS.instr list
    =
    let op = munch_op binop in
    (* Notice we fix the left hand side operand and destination the same to meet x86 instruction. *)
    let t1 = Temp.create () in
    let t2 = Temp.create () in
    let rev_acc' =
      rev_acc |> munch_exp_acc (AS.Temp t1) e1 |> munch_exp_acc (AS.Temp t2) e2
    in
    AS.Binop { op; dest; lhs = AS.Temp t1; rhs = AS.Temp t2 } :: rev_acc'

  and munch_exp : AS.operand -> T.exp -> AS.instr list =
   (* munch_exp dest exp
    * Generates instructions for dest <-- exp.
    *)
   fun dest exp ->
    (* Since munch_exp_acc returns the reversed accumulator, we must
     * reverse the list before returning. *)
    List.rev (munch_exp_acc dest exp [])

  and munch_stm stm =
    match stm with
    | T.Move mv -> munch_exp (AS.Temp mv.dest) mv.src
    | T.Return e ->
      let t = Temp.create () in
      let inst = munch_exp (AS.Temp t) e in
      inst @ [ AS.Ret { var = AS.Temp t } ]
    | Jump jmp -> [ AS.Jump { target = jmp } ]
    | T.CJump cjmp ->
      let lhs = AS.Temp (Temp.create ()) in
      let op = munch_op cjmp.op in
      let rhs = AS.Temp (Temp.create ()) in
      let lhs_inst = munch_exp lhs cjmp.lhs in
      let rhs_inst = munch_exp rhs cjmp.rhs in
      lhs_inst @ rhs_inst @ [ AS.CJump { lhs; op; rhs; target = cjmp.target_stm } ]
    | T.Label l -> [ AS.Label l ]
    | T.Seq seq -> munch_stm seq.head @ munch_stm seq.tail
    | T.Nop -> []
    | T.NExp nexp ->
      let t = AS.Temp (Temp.create ()) in
      munch_exp t nexp
  ;;

  (* To codegen a series of statements, just concatenate the results of
   * codegen-ing each statement. *)
  let gen (stm : T.program) = munch_stm stm

  let rec print_insts insts =
    match insts with
    | [] -> ()
    | h :: t ->
      let () = printf "%s\n" (AS.format h) in
      print_insts t
  ;;
end

module X86 = struct
  let oprd_ps_to_x86 (operand : AS.operand) (reg_alloc_info : Register.t Temp.Map.t)
      : AS_x86.operand
    =
    match operand with
    | Temp t ->
      let reg =
        match Temp.Map.find reg_alloc_info t with
        | Some s -> s
        | None ->
          (* Consider two cases here:
           * 1) Temp is pre-determined by input. Like l1-checkpoint %rax is written as %t-1
           * 2) Some variable that is only declared but not defined during the whole program. 
           * For example: int a; and no assignment afterwards.
           * In this case, we will use %eax to represent it. Notice that it is only a representation
           * for this uninitialized temporary, and %eax will not be assigned in the following instruction.
           * Therefore, no worry for the return value. *)
          if Temp.value t < 0 then Register.tmp_to_reg t else Register.create_no 1
      in
      if Register.need_spill reg then AS_x86.Mem (Memory.from_reg reg) else AS_x86.Reg reg
    | Reg r -> AS_x86.Reg r
    | Imm i -> AS_x86.Imm i
  ;;

  let eax = AS_x86.Reg (Register.create_no 1)
  let edx = AS_x86.Reg (Register.create_no 4)

  let gen_x86_inst_bin
      (op : AS.bin_op)
      (dest : AS_x86.operand)
      (lhs : AS_x86.operand)
      (rhs : AS_x86.operand)
      (swap : Register.t)
    =
    match op with
    | Plus -> AS_x86.safe_mov dest lhs DWORD @ AS_x86.safe_add dest rhs DWORD
    | Minus -> AS_x86.safe_mov dest lhs DWORD @ AS_x86.safe_sub dest rhs DWORD
    | Times ->
      [ AS_x86.Mov { dest = eax; src = lhs; layout = DWORD }
      ; AS_x86.Mul { src = rhs; dest = eax; layout = DWORD }
      ; AS_x86.Mov { dest; src = eax; layout = DWORD }
      ]
    | Divided_by ->
      (* Notice that lhs and rhs may be allocated on edx. 
       * So we use reg_swap to avoid override in the edx <- 0. *)
      [ AS_x86.Mov { dest = eax; src = lhs; layout = DWORD }
      ; AS_x86.Mov { dest = AS_x86.Reg swap; src = rhs; layout = DWORD }
      ; AS_x86.Cvt { layout = DWORD }
      ; AS_x86.Div { src = AS_x86.Reg swap; layout = DWORD }
      ; AS_x86.Mov { dest; src = eax; layout = DWORD }
      ]
    | Modulo ->
      [ AS_x86.Mov { dest = eax; src = lhs; layout = DWORD }
      ; AS_x86.Mov { dest = AS_x86.Reg swap; src = rhs; layout = DWORD }
      ; AS_x86.Cvt { layout = DWORD }
      ; AS_x86.Div { src = AS_x86.Reg swap; layout = DWORD }
      ; AS_x86.Mov { dest; src = edx; layout = DWORD }
      ]
    | Not_eq ->
      [ AS_x86.Mov { dest; src = eax; layout = DWORD }
      ; AS_x86.Mov { dest = AS_x86.Reg swap; src = lhs; layout = DWORD }
      ; AS_x86.XOR { dest = eax; src = eax; layout = DWORD }
      ; AS_x86.Cmp { lhs = AS_x86.Reg swap; rhs; layout = DWORD }
      ; AS_x86.SETNE { dest = eax; layout = BYTE }
      ; AS_x86.Mov { dest = AS_x86.Reg swap; src = eax; layout = DWORD }
      ; AS_x86.Mov { dest = eax; src = dest; layout = DWORD }
      ; AS_x86.Mov { dest; src = AS_x86.Reg swap; layout = DWORD }
      ]
    | _ ->
      failwith
        ("inst not implemented yet "
        ^ AS_x86.format_operand (dest :> AS_x86.operand) DWORD)
  ;;

  let rec _codegen_w_reg
      res
      inst_list
      (reg_alloc_info : Register.t Temp.Map.t)
      (reg_swap : Register.t)
    =
    match inst_list with
    | [] -> res
    | h :: t ->
      (* let () = printf "%s\n" (AS.format h) in *)
      (match h with
      | AS.Binop bin_op ->
        let dest = oprd_ps_to_x86 bin_op.dest reg_alloc_info in
        let lhs = oprd_ps_to_x86 bin_op.lhs reg_alloc_info in
        let rhs = oprd_ps_to_x86 bin_op.rhs reg_alloc_info in
        let insts = gen_x86_inst_bin bin_op.op dest lhs rhs reg_swap in
        _codegen_w_reg (res @ insts) t reg_alloc_info reg_swap
      | AS.Mov mov ->
        let dest = oprd_ps_to_x86 mov.dest reg_alloc_info in
        let src = oprd_ps_to_x86 mov.src reg_alloc_info in
        let insts = AS_x86.safe_mov dest src DWORD in
        _codegen_w_reg (res @ insts) t reg_alloc_info reg_swap
      | AS.Ret ret ->
        let var_ret = oprd_ps_to_x86 ret.var reg_alloc_info in
        (* [ "mov %rbp, %rsp"; "pop %rbp"; "ret" ] *)
        let insts = AS_x86.safe_ret var_ret QWORD in
        _codegen_w_reg (res @ insts) t reg_alloc_info reg_swap
      | AS.Label l -> _codegen_w_reg (res @ [ AS_x86.Label l ]) t reg_alloc_info reg_swap
      | AS.Jump jp ->
        _codegen_w_reg (res @ [ AS_x86.Jump jp.target ]) t reg_alloc_info reg_swap
      | AS.CJump cjp ->
        let lhs = oprd_ps_to_x86 cjp.lhs reg_alloc_info in
        let rhs = oprd_ps_to_x86 cjp.rhs reg_alloc_info in
        let target = cjp.target in
        let inst =
          match cjp.op with
          | Equal_eq -> AS_x86.safe_je lhs rhs DWORD
          | Greater -> AS_x86.safe_jg lhs rhs DWORD
          | Greater_eq -> AS_x86.safe_jge lhs rhs DWORD
          | Less -> AS_x86.safe_jl lhs rhs DWORD
          | Less_eq -> AS_x86.safe_jle lhs rhs DWORD
          | Not_eq -> AS_x86.safe_jne lhs rhs DWORD target
          | _ -> failwith "conditional jump op should can only be relop."
        in
        _codegen_w_reg (res @ inst) t reg_alloc_info reg_swap
      | _ -> _codegen_w_reg res t reg_alloc_info reg_swap)
  ;;

  let gen (inst_list : AS.instr list) (reg_alloc_info : (Temp.t * Register.t) option list)
      : AS_x86.instr list
    =
    let reg_alloc =
      List.fold reg_alloc_info ~init:Temp.Map.empty ~f:(fun acc x ->
          match x with
          | None -> acc
          | Some x ->
            (match x with
            | temp, reg -> Temp.Map.set acc ~key:temp ~data:reg))
    in
    let reg_swap = Register.swap () in
    _codegen_w_reg [] inst_list reg_alloc reg_swap
  ;;
end
