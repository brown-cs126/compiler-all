(* 
 * Notice the difference between CST and AST
 * CST is basically transferred from source code literaly.
 * AST add more structure statement unit based on CST, and it looks like a tree.
 *
 * Statement level benefit:
 * To be specific, AST classify statement from CST into below
 * 1) Asign(x,e)
 * 2) if(e,s,s)
 * 3) while(e,s)
 * 4) return(e)
 * 5) nop
 * 6) seq(s,s)
 * 7) declare(x,t,s)
 * The obvious advantage is that we can handle variable namespace more efficiently.
 * We can see if the use of x is in a declare statement. Notice that the use of x
 * may be nested in many seq statement in declare(x,t,s).
 * In addition, we will simplify for from CST to while statement in AST.
 * This will reduce the Intermediate Representation.
 *
 * Expression level benefit:
 *  - logical operation && || ^ can be denoted in ternary expression, 
 *    logical operation anymore.
 *
 * No operation on function level elaboration.
 *
 * Elaborate typedef to primitive data type(int, bool, void). 
 * So AST datatype do not need to bother custom types.
 *
 * Provide elab_lvalue for assignment.
 *
 * Forbide elab e1 asnop e2 as e1 = e1 op e2 for possible side effect.
 *
 * Author: Tianbo Hao <tianboh@alumni.cmu.edu>
 *)

module Mark = Util.Mark
module Symbol = Util.Symbol
open Core

let tc_errors : Util.Error_msg.t = Util.Error_msg.create ()

let error ~msg src_span =
  Util.Error_msg.error tc_errors src_span ~msg;
  raise Util.Error_msg.Error
;;

(* cst type including custom type(int, bool, void, custom type) 
 * to cst primitive type(int, bool, void) *)
let ct2pt = ref Symbol.Map.empty

(* Store declared and defined function names. 
 * Do not record parameter type and return type.
 * It is only used to check whether func name and 
 * typedef name conflict or not. *)
let func_env = ref Symbol.Set.empty

let elab_ptype = function
  | Cst.Int -> Ast.Int
  | Cst.Bool -> Ast.Bool
  | Cst.Void -> Ast.Void
  | Cst.Ctype _ -> failwith "elab_ptype should only handle primitive types"
  | Cst.Pointer _ -> failwith "not yet"
  | Cst.Array _ -> failwith "not yet"
  | Cst.Struct _ -> failwith "not yet"
;;

let elab_type ctype =
  let ptype =
    match ctype with
    | Cst.Int -> Cst.Int
    | Cst.Bool -> Cst.Bool
    | Cst.Void -> Cst.Void
    | Cst.Ctype c -> Symbol.Map.find_exn !ct2pt c
    | Cst.Pointer _ -> failwith "not yet"
    | Cst.Array _ -> failwith "not yet"
    | Cst.Struct _ -> failwith "not yet"
  in
  elab_ptype ptype
;;

let elab_asnop (asnop : Cst.asnop) : Ast.asnop =
  match asnop with
  | Asn -> Asn
  | Plus_asn -> Plus_asn
  | Minus_asn -> Minus_asn
  | Times_asn -> Times_asn
  | Div_asn -> Div_asn
  | Mod_asn -> Mod_asn
  | And_asn -> And_asn
  | Hat_asn -> Hat_asn
  | Or_asn -> Or_asn
  | Left_shift_asn -> Left_shift_asn
  | Right_shift_asn -> Right_shift_asn
;;

(* 
 * CST exp -> AST exp
 * 1) Remove unary op in AST, including -, !, and ~
 * 2) Remove logical-logical op, indicating input and output are both logical ,
 * in AST, including && and ||
 *)
let rec elab_exp = function
  | Cst.Var var ->
    if Symbol.Map.mem !ct2pt var then error ~msg:"exp name conflict with typename" None;
    Ast.Var var
  | Cst.Const_int i -> Ast.Const_int i
  | Cst.True -> Ast.True
  | Cst.False -> Ast.False
  | Cst.Binop binop -> elab_binop binop.op binop.lhs binop.rhs
  | Cst.Unop unop -> elab_unop unop.op unop.operand
  | Cst.Terop terop -> elab_terop terop.cond terop.true_exp terop.false_exp
  | Cst.Fcall fcall ->
    Ast.Fcall { func_name = fcall.func_name; args = List.map fcall.args ~f:elab_mexp }
  | Cst.Dot dot -> Ast.EDot { struct_obj = elab_mexp dot.struct_obj; field = dot.field }
  | Cst.Arrow arrow ->
    let struct_obj = Mark.naked (Ast.EDeref { ptr = elab_mexp arrow.struct_ptr }) in
    Ast.EDot { struct_obj; field = arrow.field }
  | Cst.Deref deref -> Ast.EDeref { ptr = elab_mexp deref.ptr }
  | Cst.Nth nth -> Ast.ENth { arr = elab_mexp nth.arr; index = elab_mexp nth.index }
  | Cst.NULL -> Ast.NULL
  | Cst.Alloc alloc -> Ast.Alloc { t = elab_type alloc.t }
  | Cst.Alloc_arr alloc_arr ->
    Ast.Alloc_arr { t = elab_type alloc_arr.t; e = elab_mexp alloc_arr.e }

(* CST mexp -> AST mexp *)
and elab_mexp (cst_mexp : Cst.mexp) =
  let src_span = Mark.src_span cst_mexp in
  let exp = Mark.data cst_mexp in
  let strip_exp_ast = elab_exp exp in
  Mark.mark' strip_exp_ast src_span

and elab_binop (binop : Cst.binop) (lhs : Cst.mexp) (rhs : Cst.mexp) : Ast.exp =
  let lhs_ast = elab_mexp lhs in
  let rhs_ast = elab_mexp rhs in
  match binop with
  (* Use shortcircuit to handle && and || *)
  | Cst.And_and ->
    Ast.Terop { cond = lhs_ast; true_exp = rhs_ast; false_exp = Mark.naked Ast.False }
  | Cst.Or_or ->
    Ast.Terop { cond = lhs_ast; true_exp = Mark.naked Ast.True; false_exp = rhs_ast }
  (* Rest is only type transformation. *)
  | Cst.Plus -> Ast.Binop { op = Ast.Plus; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Minus -> Ast.Binop { op = Ast.Minus; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Times -> Ast.Binop { op = Ast.Times; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Divided_by -> Ast.Binop { op = Ast.Divided_by; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Modulo -> Ast.Binop { op = Ast.Modulo; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.And -> Ast.Binop { op = Ast.And; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Or -> Ast.Binop { op = Ast.Or; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Hat -> Ast.Binop { op = Ast.Hat; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Right_shift -> Ast.Binop { op = Ast.Right_shift; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Left_shift -> Ast.Binop { op = Ast.Left_shift; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Equal_eq -> Ast.Binop { op = Ast.Equal_eq; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Greater -> Ast.Binop { op = Ast.Greater; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Greater_eq -> Ast.Binop { op = Ast.Greater_eq; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Less -> Ast.Binop { op = Ast.Less; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Less_eq -> Ast.Binop { op = Ast.Less_eq; lhs = lhs_ast; rhs = rhs_ast }
  | Cst.Not_eq -> Ast.Binop { op = Ast.Not_eq; lhs = lhs_ast; rhs = rhs_ast }

and elab_unop (unop : Cst.unop) (operand : Cst.mexp) : Ast.exp =
  let operand_ast = elab_mexp operand in
  match unop with
  | Cst.Negative ->
    let lhs = Mark.naked (Ast.Const_int Int32.zero) in
    Ast.Binop { op = Ast.Minus; lhs; rhs = operand_ast }
  | Cst.Excalmation_mark ->
    Ast.Binop { op = Ast.Equal_eq; lhs = operand_ast; rhs = Mark.naked Ast.False }
  | Cst.Dash_mark ->
    (* -1 is 1111 1111 in 2's complement representation *)
    let lhs = Mark.naked (Ast.Const_int Int32.minus_one) in
    Ast.Binop { op = Ast.Hat; lhs; rhs = operand_ast }

and elab_terop (cond : Cst.mexp) (true_exp : Cst.mexp) (false_exp : Cst.mexp) : Ast.exp =
  let cond_ast = elab_mexp cond in
  let true_exp_ast = elab_mexp true_exp in
  let false_exp_ast = elab_mexp false_exp in
  Ast.Terop { cond = cond_ast; true_exp = true_exp_ast; false_exp = false_exp_ast }
;;

let rec elab_lvalue = function
  | Cst.Var var ->
    if Symbol.Map.mem !ct2pt var then error ~msg:"exp name conflict with typename" None;
    Ast.Ident var
  | Cst.Const_int _ -> failwith "lvalue not accept int const"
  | Cst.True | Cst.False -> failwith "lvalue not accept boolean const"
  | Cst.Binop _ | Cst.Unop _ | Cst.Terop _ ->
    failwith "lvalue not accept binop, unop, terop"
  | Cst.Fcall _ -> failwith "lvalue not accept fcall"
  | Cst.Dot dot ->
    Ast.LVDot { struct_obj = elab_mlvalue dot.struct_obj; field = dot.field }
  | Cst.Arrow arrow ->
    let struct_obj = Mark.naked (Ast.LVDeref { ptr = elab_mlvalue arrow.struct_ptr }) in
    Ast.LVDot { struct_obj; field = arrow.field }
  | Cst.Deref deref -> Ast.LVDeref { ptr = elab_mlvalue deref.ptr }
  | Cst.Nth nth -> Ast.LVNth { arr = elab_mlvalue nth.arr; index = elab_mexp nth.index }
  | Cst.NULL -> failwith "lvalue not accept NULL"
  | Cst.Alloc _ | Cst.Alloc_arr _ -> failwith "cannot alloc at lvalue"

and elab_mlvalue mlvalue_cst =
  let src_span = Mark.src_span mlvalue_cst in
  let lvalue_cst = Mark.data mlvalue_cst in
  let lvalue_ast = elab_lvalue lvalue_cst in
  Mark.mark' lvalue_ast src_span
;;

let rec elab_blk (cst : Cst.block) (acc : Ast.mstm) : Ast.mstm =
  match cst with
  | [] -> acc
  | h :: t ->
    let ast_head, cst_tail = elab_stm h t in
    let acc = Ast.Seq { head = acc; tail = ast_head } in
    elab_blk cst_tail (Mark.naked acc)

(* Though we are elaborating current statement, the tail is required
 * during process because in some cases, like declare, we need the following 
 * context for AST unit. Also, we need to return the tail after process to 
 * avoid redo elaboration in elab_blk function.
 *
 * Return: Elaborated AST statement from CST head and the remaining CST tail.
 *)
and elab_stm (head : Cst.mstm) (tail : Cst.mstms) : Ast.mstm * Cst.block =
  let src_span = Mark.src_span head in
  match Util.Mark.data head with
  | Cst.Simp simp -> elab_simp simp src_span tail
  | Cst.Control ctl -> elab_control ctl src_span, tail
  | Cst.Block blk -> elab_blk blk (Mark.naked Ast.Nop), tail

(* simp: CST simp statement
 * src_span: location of simp in source code, thie will be marked to AST.
 * This is crucial for pinpoint the location during semantic analysis in AST
 * tail: remaining CST statements to process
 * Return AST head and remaining CST tails *)
and elab_simp (simp : Cst.simp) (src_span : Mark.src_span option) (tail : Cst.mstms)
    : Ast.mstm * Cst.block
  =
  match simp with
  | Cst.Declare decl -> elab_declare decl src_span tail
  | Cst.Assign asn ->
    let name = elab_mlvalue asn.name in
    let value = elab_mexp asn.value in
    let op = elab_asnop asn.op in
    let asn_ast = Ast.Assign { name; value; op } in
    Mark.mark' asn_ast src_span, tail
  | Cst.Sexp exp -> Mark.mark' (Ast.Sexp (elab_mexp exp)) src_span, tail

and elab_declare (decl : Cst.decl) (src_span : Mark.src_span option) (tail : Cst.mstms) =
  match decl with
  | New_var var ->
    let ast_tail = elab_blk tail (Mark.naked Ast.Nop) in
    if Symbol.Map.mem !ct2pt var.name
    then error None ~msg:"decl var name conflict with typedef name";
    let decl_ast =
      Ast.Declare { t = elab_type var.t; name = var.name; value = None; tail = ast_tail }
    in
    Mark.mark' decl_ast src_span, []
  | Init init ->
    let ast_tail = elab_blk tail (Mark.naked Ast.Nop) in
    if Symbol.Map.mem !ct2pt init.name
    then error None ~msg:"init var name conflict with typedef name";
    let decl_ast =
      Ast.Declare
        { t = elab_type init.t
        ; name = init.name
        ; value = Some (elab_mexp init.value)
        ; tail = ast_tail
        }
    in
    Mark.mark' decl_ast src_span, []

(* Return: AST statement. *)
and elab_control ctl (src_span : Mark.src_span option) =
  match ctl with
  | If if_stm ->
    let false_stm, _ =
      match if_stm.false_stm with
      | None -> Mark.naked Ast.Nop, []
      | Some s -> elab_stm s []
    in
    let true_stm, _ = elab_stm if_stm.true_stm [] in
    let if_ast = Ast.If { cond = elab_mexp if_stm.cond; true_stm; false_stm } in
    Mark.mark' if_ast src_span
  | While while_stm ->
    let body, _ = elab_stm while_stm.body [] in
    let cond = elab_mexp while_stm.cond in
    let while_ast = Ast.While { cond; body } in
    Mark.mark' while_ast src_span
  (* We elaborate CST "for" to AST "while" for simplicity *)
  | For for_stm ->
    let body_cst =
      match for_stm.iter with
      | None -> Cst.Block [ for_stm.body ]
      | Some simp ->
        let src_span_iter = Mark.src_span simp in
        let iter_cst =
          match Mark.data simp with
          | Cst.Declare _ ->
            let loc = Mark.src_span simp in
            error ~msg:(sprintf "Cannot decalre variable at for iter.") loc
          | _ -> Cst.Simp (Mark.data simp)
        in
        Cst.Block [ for_stm.body; Mark.mark' iter_cst src_span_iter ]
    in
    let src_span_body = Mark.src_span for_stm.body in
    let while_cst =
      Cst.While { cond = for_stm.cond; body = Mark.mark' body_cst src_span_body }
    in
    let for_ast =
      match for_stm.init with
      | None -> elab_control while_cst src_span_body
      | Some init ->
        let src_span_init = Mark.src_span init in
        let init_cst = Cst.Simp (Mark.data init) in
        let init_cst = Mark.mark' init_cst src_span_init in
        let cst_program =
          [ init_cst; Mark.mark' (Cst.Control while_cst) src_span_body ]
        in
        elab_blk cst_program (Mark.naked Ast.Nop)
    in
    for_ast
  | Return ret ->
    (match ret with
    | Some ret ->
      let src_span_ret = Mark.src_span ret in
      let e_ast = elab_mexp ret in
      let ret_ast = Mark.mark' (Ast.Return (Some e_ast)) src_span_ret in
      ret_ast
    | None -> Mark.naked (Ast.Return None))
  | Assert e ->
    let src_span = Mark.src_span e in
    let e_ast = elab_mexp e in
    let assert_ast = Ast.Assert e_ast in
    Mark.mark' assert_ast src_span
;;

let elab_param (param : Cst.param) : Ast.param = { t = elab_type param.t; i = param.i }

let elab_fdecl ret_type func_name (par_type : Cst.param list) =
  func_env := Symbol.Set.add !func_env func_name;
  if Symbol.Map.mem !ct2pt func_name
  then error None ~msg:"decl func name conflict with typename";
  List.iter par_type ~f:(fun par ->
      if Symbol.Map.mem !ct2pt par.i
      then error ~msg:"decl func par conflict with type name" None);
  let ret_type = elab_type ret_type in
  Ast.Fdecl { ret_type; func_name; pars = List.map par_type ~f:elab_param }
;;

let elab_fdefn (ret_type : Cst.dtype) (func_name : Symbol.t) par_type blk =
  func_env := Symbol.Set.add !func_env func_name;
  if Symbol.Map.mem !ct2pt func_name
  then error None ~msg:"defn func name conflict with typename"
  else
    Ast.Fdefn
      { ret_type = elab_type ret_type
      ; func_name
      ; pars = List.map par_type ~f:elab_param
      ; blk = elab_blk blk (Mark.naked Ast.Nop)
      }
;;

(* Rules to follow
 * 1) cannot collid with names of function or variable
 * 2) The name of a defined type is visible after its definition. 
 * Type names may be defined only once *)
let elab_typedef t t_var =
  let env' = !ct2pt in
  let dest_type =
    match t with
    | Cst.Ctype s -> Symbol.Map.find_exn env' s
    | Cst.Int -> Cst.Int
    | Cst.Bool -> Cst.Bool
    | Cst.Void -> error ~msg:"dest type cannot be void" None
    | Cst.Pointer _ -> failwith "not yet"
    | Cst.Array _ -> failwith "not yet"
    | Cst.Struct _ -> failwith "not yet"
  in
  if Symbol.Set.mem !func_env t_var then error None ~msg:"type name already exist";
  let env' =
    match Symbol.Map.add env' ~key:t_var ~data:dest_type with
    | `Duplicate -> error None ~msg:"type name already exist"
    | `Ok s -> s
  in
  ct2pt := env';
  Ast.Typedef { t = elab_type t; t_var }
;;

let rec elab (cst : Cst.program) (acc : Ast.program) : Ast.program =
  match cst with
  | [] -> List.rev acc
  | h :: t ->
    (match h with
    | Cst.Fdecl fdecl ->
      elab t (elab_fdecl fdecl.ret_type fdecl.func_name fdecl.par_type :: acc)
    | Cst.Fdefn fdenf ->
      elab t (elab_fdefn fdenf.ret_type fdenf.func_name fdenf.par_type fdenf.blk :: acc)
    | Cst.Typedef typedef -> elab t (elab_typedef typedef.t typedef.t_var :: acc)
    | Cst.Sdefn _ -> failwith "not yet"
    | Cst.Sdecl _ -> failwith "not yet")
;;

let elaborate (cst : Cst.program) : Ast.program = elab cst []
