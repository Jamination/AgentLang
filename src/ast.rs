// AST for AL.

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Pos {
    pub file: u16,
    pub line: u32,
    pub col: u16,
}

#[derive(Clone, Debug)]
pub struct Diag {
    pub pos: Pos,
    pub msg: String,
}

#[derive(Clone, Debug)]
pub enum TypeAst {
    Name(String, Vec<TypeAst>, Pos),
    Ptr(Box<TypeAst>),
    Slice(Box<TypeAst>),
    Array(Box<Expr>, Box<TypeAst>),
    Fn(Vec<TypeAst>, Option<Box<TypeAst>>),
    Tuple(Vec<TypeAst>),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnOp {
    Neg,
    Not,
    BitNot,
    Addr,
    Deref,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    And,
    Or,
    Xor,
    Shl,
    Shr,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    LAnd,
    LOr,
}

#[derive(Clone, Debug)]
pub struct Expr {
    pub k: EK,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub enum EK {
    Int(u64),
    Float(f64),
    Str(Vec<u8>),
    Bool(bool),
    Nil,
    Ident(String),
    Un(UnOp, Box<Expr>),
    Bin(BinOp, Box<Expr>, Box<Expr>),
    Call(Box<Expr>, Vec<Expr>),
    Index(Box<Expr>, Vec<Expr>),
    Slice(Box<Expr>, Option<Box<Expr>>, Option<Box<Expr>>),
    Field(Box<Expr>, String),
    Lit(Box<Expr>, Vec<(Option<String>, Expr)>),
    TypeE(TypeAst),
    If(Box<Expr>, Block, Block),
    Tuple(Vec<Expr>),
    Match(Box<Expr>, Vec<MatchArm>),
}

#[derive(Clone, Debug)]
pub struct MatchArm {
    pub pats: Vec<Pat>,
    pub body: Block,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub enum Pat {
    Wild,
    // constant expression (int, enum constant name, string, ...)
    Const(Expr),
    // Variant(bindings...)
    Variant(String, Vec<String>, Pos),
}

#[derive(Clone, Debug)]
pub struct Block {
    pub stmts: Vec<Stmt>,
    pub end: Pos,
}

#[derive(Clone, Debug)]
pub struct Stmt {
    pub k: SK,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub enum SK {
    Expr(Expr),
    Let(Vec<String>, Expr),
    MultiAssign(Vec<Expr>, Expr),
    Var(String, Option<TypeAst>, Option<Expr>),
    Assign(Expr, Option<BinOp>, Expr),
    If(Expr, Block, Option<Block>),
    While(Expr, Block),
    Loop(Block),
    For {
        var: String,
        var2: Option<String>,
        lo: Expr,
        hi: Option<Expr>,
        incl: bool,
        step: Option<Expr>,
        body: Block,
    },
    Return(Option<Expr>),
    Break,
    Continue,
    Assert(Expr, Option<Expr>),
    Block(Block),
    Defer(Block),
}

#[derive(Clone, Debug)]
pub struct FnDecl {
    pub name: String,
    pub tparams: Vec<String>,
    pub params: Vec<(String, TypeAst)>,
    pub ret: Option<TypeAst>,
    pub body: Block,
    pub pos: Pos,
    pub inline: i8, // 1 = always inline, -1 = never, 0 = auto
}

#[derive(Clone, Debug)]
pub struct StructDecl {
    pub name: String,
    pub tparams: Vec<String>,
    pub fields: Vec<(String, TypeAst)>,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub struct EnumDecl {
    pub name: String,
    pub tparams: Vec<String>,
    pub variants: Vec<(String, Vec<TypeAst>)>,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub struct ConstDecl {
    pub name: String,
    pub ty: Option<TypeAst>,
    pub val: Expr,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub struct GlobalDecl {
    pub name: String,
    pub ty: Option<TypeAst>,
    pub init: Option<Expr>,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub struct TestDecl {
    pub name: String,
    pub body: Block,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub enum Decl {
    Fn(FnDecl),
    Struct(StructDecl),
    Enum(EnumDecl),
    Const(ConstDecl),
    Global(GlobalDecl),
    Test(TestDecl),
    Use(String, Pos),
}
