module Register = Var.X86_reg
module Memory = Var.Memory

type operand =
  | Imm of Int32.t
  | Reg of Register.t
  | Mem of Memory.t

type instr =
  | Add of {src:operand; dest:operand}
  | Sub of {src:operand; dest:operand}
  | Mul of {src:operand}
  | Div of {src:operand}
  | Mod of {src:operand}
    (* dest <- lhs op rhs *)
    (* | Binop of
        { op : bin_op
        ; dest : [`Reg of Register.t]
        ; lhs : operand
        ; rhs : operand
        } *)
    (* dest <- src *)
    | Mov of
        { dest : operand
        ; src : operand
        }
    | Cdq
    | Ret
    (* Assembly directive. *)
    | Directive of string
    (* Human-friendly comment. *)
    | Comment of string

val format_prologue : int -> string

val format_epilogue : unit -> string

val format : instr -> string

val format_operand : operand -> string