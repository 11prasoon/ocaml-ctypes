(* TODO: better array support, perhaps based on bigarrays integration *)

module C =
struct
  exception IncompleteType
  exception ModifyingSealedType
  exception Unsupported of string

  module Raw = Ffi_raw
  module RawTypes = Ffi_raw.Types

  type 'a structure_type = {
    tag: string;
    bufspec: Raw.bufferspec;

    (* Whether the struct can be passed or returned by value.  For the
       moment, at least, we don't support passing structs that contain
       unions or arrays as members *)
    mutable passable: bool;

    mutable ctype: 'a Raw.structure RawTypes.ctype option;

  (* TODO: perhaps keep references to fields that might be collected,
     at least until we seal the structure. *)
  }

  type 'a union_type = {
    utag: string;
    mutable ucomplete: bool;
    mutable usize: int;
    mutable ualignment: int;
  }

  type _ typ =
      Void : unit typ
    | Primitive : 'a RawTypes.ctype -> 'a typ
    | Pointer : 'a typ -> 'a ptr typ
    | Struct : 'a structure_type -> 'a structure typ
    | Union : 'a union_type -> 'a union typ
    | Array : 'a typ * int -> 'a array typ
    | FunctionPointer : ('a -> 'b) fn -> ('a -> 'b) typ
  and _ fn =
    (* The flag indicates whether we should check errno *)
    | Returns : bool * 'a typ -> 'a fn
    | Function : 'a typ * 'b fn -> ('a -> 'b) fn
  and 'a ptr = { reftype : 'a typ;
                 raw_ptr : Raw.immediate_pointer;
                 pmanaged : Raw.managed_buffer option;
                 pbyte_offset : int }
  and 'a array = { astart: 'a ptr;
                   alength : int }
  and 'a union = { union : 'a union ptr }
  and 'a structure = { structure : 'a structure ptr }

  type _ ccallspec =
      Call : bool * (Raw.immediate_pointer -> 'a) -> 'a ccallspec
    | WriteArg : ('a -> Raw.immediate_pointer -> unit) * 'b ccallspec -> ('a -> 'b) ccallspec

  type arg_type = ArgType : 'b RawTypes.ctype -> arg_type

  let rec sizeof : 'a. 'a typ -> int
    = fun (type a) (t : a typ) -> match t with
        Void                      -> raise IncompleteType
      | Primitive p               -> RawTypes.sizeof p
      | Struct { ctype = None }   -> raise IncompleteType
      | Struct { ctype = Some p } -> RawTypes.sizeof p
      | Union { ucomplete=false } -> raise IncompleteType
      | Union { usize }           -> usize
      | Array (t, i)              -> i * sizeof t
      | Pointer _                 -> RawTypes.(sizeof pointer)
      | FunctionPointer _         -> RawTypes.(sizeof pointer)

  let rec alignment : 'a. 'a typ -> int
    = fun (type a) (t : a typ) -> match t with
        Void                      -> raise IncompleteType
      | Primitive p               -> RawTypes.alignment p
      | Struct { ctype = None }   -> raise IncompleteType
      | Struct { ctype = Some p } -> RawTypes.alignment p
      | Union { ucomplete=false } -> raise IncompleteType
      | Union { ualignment }      -> ualignment
      | Array (t, i)              -> alignment t
      | Pointer _                 -> RawTypes.(alignment pointer)
      | FunctionPointer _         -> RawTypes.(alignment pointer)

  let passable (type a) (t : a typ) = match t with
        Void                       -> true
      | Primitive p                -> true
      | Struct { ctype = None }    -> raise IncompleteType
      | Struct { passable }        -> passable
      | Union { ucomplete = false} -> raise IncompleteType
      | Union _                    -> false
      | Array _                    -> false
      | Pointer _                  -> true
      | FunctionPointer _          -> true

  let arg_type : 'a. 'a typ -> arg_type
    = fun (type a) (t : a typ) -> match t with
      | Void -> ArgType RawTypes.void
      | Primitive p -> ArgType p
      | Struct {ctype=None} -> raise IncompleteType
      | Struct {ctype=Some p} as s -> ArgType p
      | Pointer reftype -> ArgType RawTypes.pointer
      | FunctionPointer fn -> ArgType RawTypes.pointer
      (* The following cases should never happen; non-struct aggregate
         types are excluded during type construction. *)
      | Union _ -> assert false
      | Array _ -> assert false

  (*
    call addr callspec return (fun buffer ->
    write arg_1 buffer v_1
    write arg_2 buffer v_2
    ...
    write arg_n buffer v_n)
  *)
  let rec invoke : 'a.string option -> 'a ccallspec -> (Raw.immediate_pointer -> unit) list -> Raw.bufferspec -> Raw.immediate_pointer -> 'a
    = fun name (type a) (fn : a ccallspec) -> match fn with
      | Call (check_errno, read_return_value) ->
        let call = match check_errno, name with
          | true, Some name -> Raw.call_errno name 
          | true, None      -> Raw.call_errno "" 
          | false, _        -> Raw.call
        in
        fun writers callspec addr ->
          call addr callspec
            (fun buf -> List.iter (fun w -> w buf) writers)
            read_return_value
      | WriteArg (write, ccallspec) ->
        let next = invoke name ccallspec in
        fun writers callspec addr v ->
          next (write v :: writers) callspec addr

  let rec prep_callspec : 'a. Raw.bufferspec -> 'a typ -> unit
    = fun callspec ty ->
      let ArgType ctype = arg_type ty in
      Raw.prep_callspec callspec ctype

  and add_argument : 'a. Raw.bufferspec -> 'a typ -> int
    = fun callspec (type a) (ty : a typ) -> match ty with
      | Void -> 0
      | _    -> let ArgType ctype = arg_type ty in
                Raw.add_argument callspec ctype

  and build_callspec : 'a. 'a fn -> Raw.bufferspec -> 'a -> Raw.boxedfn =
    fun (type a) fn callspec -> match (fn : a fn) with
      | Returns (_, ty) ->
        let _ = prep_callspec callspec ty
        and write_rv = write ty in
        fun f -> Raw.Done (write_rv ~offset:0 f)
      | Function (p, f) ->
        let _ = add_argument callspec p
        and box = build_callspec f callspec
        and read = build p ~offset:0 in
        fun f -> Raw.Fn (fun buf -> box (f (read buf)))

  (* Describes how to read a value, e.g. from a return buffer *)
  and build : 'a. 'a typ -> offset:int -> Raw.immediate_pointer -> 'a =
    fun (type a) (t : a typ) -> match t with
      | Void ->
        (Raw.read RawTypes.void : offset:int -> Raw.immediate_pointer -> a)
      | Primitive p ->
        Raw.read p
      | Struct {ctype=None} ->
        raise IncompleteType
      | Struct ({ctype=Some p}) as reftype ->
        (fun ~offset buf -> 
          let m = Raw.read p ~offset buf in
          { structure = 
              { pmanaged = Some m;
                reftype;
                raw_ptr = Raw.block_address m;
                pbyte_offset = 0}})
      | Pointer reftype ->
        (fun ~offset buf -> 
          {raw_ptr=Raw.read RawTypes.pointer ~offset buf;
           pbyte_offset = 0;
           reftype;
           pmanaged = None})
      | FunctionPointer f ->
        let build_fun = build_function f in
        (fun ~offset buf -> build_fun (Raw.read RawTypes.pointer ~offset buf))
      (* The following cases should never happen; non-struct aggregate
         types are excluded during type construction. *)
      | Union _ -> assert false
      | Array _ -> assert false

  and write : 'a. 'a typ -> offset:int -> 'a -> Raw.immediate_pointer -> unit =
    fun (type a) (t : a typ) -> match t with
      | Void ->
        ((fun ~offset _ _ -> ()) : offset:int -> a -> Raw.immediate_pointer -> unit)
      | Primitive p ->
        Raw.write p
      | Pointer reftype ->
        (fun ~offset {raw_ptr; pbyte_offset} -> 
          Raw.write RawTypes.pointer ~offset
            (Raw.pointer_plus raw_ptr pbyte_offset))
      | FunctionPointer fn ->
        let cs' = Raw.allocate_callspec () in
        let cs = build_callspec fn cs' in
        (fun ~offset f ->
          Raw.write RawTypes.pointer ~offset
            (Raw.make_function_pointer cs' (cs f)))
      | Struct {ctype=None} ->
        raise IncompleteType
      | Struct {ctype=Some _} as s ->
        let size = sizeof s in
        (fun ~offset {structure={raw_ptr=src; pbyte_offset=src_offset}} dst ->
          Raw.memcpy ~size ~dst ~dst_offset:offset ~src ~src_offset)
      | Union {ucomplete=false} ->
        raise IncompleteType
      | Union {usize=size} ->
        (fun ~offset {union={raw_ptr=src; pbyte_offset=src_offset}} dst ->
          Raw.memcpy ~size ~dst ~dst_offset:offset ~src ~src_offset)
      | Array _ as a ->
        let size = sizeof a in
        (fun ~offset {astart={raw_ptr=src; pbyte_offset=src_offset}} dst ->
          Raw.memcpy ~size ~dst ~dst_offset:offset ~src ~src_offset)
          
  (*
    callspec = allocate_callspec ()
    arg_1 = add_argument callspec argtype
    arg_2 = add_argument callspec argtype
    ...
    arg_n = add_argument callspec argtype
    return = prep_callspec callspec rettype
  *)
  and build_ccallspec : 'a. 'a fn -> Raw.bufferspec -> 'a ccallspec
    = fun (type a) (fn : a fn) callspec -> match fn with
      | Returns (check_errno, t) ->
        let () = prep_callspec callspec t in
        (Call (check_errno, build t ~offset:0) : a ccallspec)
      | Function (p, f) ->
        let offset = add_argument callspec p
        and rest = build_ccallspec f callspec in
        WriteArg (write p ~offset, rest)

  and build_function : 'a. ?name:string -> 'a fn -> RawTypes.voidp -> 'a
    = fun ?name fn ->
      let c = Raw.allocate_callspec () in
      let e = build_ccallspec fn c in
      invoke name e [] c

  module Ptr =
  struct
    type 'a t = 'a ptr = { reftype : 'a typ;
                           raw_ptr : Raw.immediate_pointer;
                           pmanaged : Raw.managed_buffer option;
                           pbyte_offset : int }

    let null : unit ptr = {raw_ptr = RawTypes.null;
                           reftype = Void;
                           pbyte_offset = 0;
                           pmanaged=None}

    let (!) : 'a. 'a t -> 'a
      = fun (type a) ({raw_ptr; reftype; pbyte_offset=offset} as ptr : a t) ->
        match reftype with
          | Void -> raise IncompleteType
          | Union {ucomplete=false} -> raise IncompleteType
          | Struct {ctype=None} -> raise IncompleteType
          (* If it's a reference type then we take a reference *)
          | Union _ -> ({union = ptr } : a)
          | Struct _ -> { structure = ptr}
          | Array (elemtype, alength) ->
            { astart = {ptr with reftype = elemtype}; alength }
          (* If it's a value type then we cons a new value. *)
          | _ -> build reftype ~offset raw_ptr

    let diff : 'a. 'a t -> 'a t -> int =
      fun {pbyte_offset = o1; reftype} {pbyte_offset = o2} ->
        (* We assume the pointers are properly aligned, or at least that
           the difference is a multiple of sizeof reftype. *)
        (o2 - o1) / sizeof reftype 

    let (+) : 'a. 'a t -> int -> 'a t =
      fun ({pbyte_offset; reftype} as p) x ->
        {p with pbyte_offset = pbyte_offset + (x * sizeof reftype)}

    let (-) : 'a. 'a t -> int -> 'a t =
      fun p x -> p + (-x)

    let (:=) : 'a. 'a t -> 'a -> unit
      = fun (type a) ({reftype; raw_ptr; pbyte_offset=offset} : a t) ->
        fun v -> write reftype ~offset v raw_ptr
              
    let from_voidp : 'a. 'a typ -> unit ptr -> 'a ptr =
      fun reftype p -> {p with reftype}
        
    let to_voidp : 'a. 'a ptr -> unit ptr =
      fun p -> {p with reftype = Void}

    let allocate : 'a. 'a typ -> count:int -> 'a ptr
      = fun (type a) (reftype : a typ) ~count ->
        let pmanaged = Raw.allocate (count * sizeof reftype) in
        { reftype ; pbyte_offset = 0;
          raw_ptr = Raw.block_address pmanaged;
          pmanaged = Some pmanaged }

    let make : 'a. 'a typ -> 'a -> 'a ptr
      = fun (type a) (reftype : a typ) (v : a) ->
        let p = allocate ~count:1 reftype in begin
          p := v;
          p
        end
  end

  module Array =
  struct
    type 'a t = 'a array

    let check_bound { alength } i =
      if i >= alength then
        invalid_arg "index out of bounds"

    let unsafe_get { astart } n =
      Ptr.(!(astart + n))

    let unsafe_set { astart } n v =
      Ptr.((astart + n) := v)

    let get arr n =
      check_bound arr n;
      unsafe_get arr n

    let set arr n v =
      check_bound arr n;
      unsafe_set arr n v

    let start {astart} = astart
    let length {alength} = alength
    let from_ptr astart alength = {astart; alength}

    let fill ({ alength } as arr) v =
      for i = 0 to alength - 1 do unsafe_set arr i v done

    let make : 'a. 'a typ -> ?initial:'a -> int -> 'a t
      = fun (type a) reftype ?initial alength ->
        (* TODO: simplify, using Ptr.allocate *)
        let p = Raw.allocate (alength * (sizeof reftype)) in
        let arr = { alength;
                    astart = { reftype; pbyte_offset = 0;
                               raw_ptr = Raw.block_address p;
                               pmanaged = Some p } } in
        match initial with
          | None -> arr
          | Some v -> fill arr v; arr

    let of_list typ list =
      let arr = make typ (List.length list) in
      List.iteri (set arr) list;
      arr

    let to_list a =
      let l = ref [] in
      for i = length a - 1 downto 0 do
        l := get a i :: !l
      done;
      !l
  end

  module Struct =
  struct
    type 's t = 's structure = { structure : 's structure ptr }
    type ('a, 's) field  = { ftype: 'a typ;
                             foffset: int }
        
    let tag tag = Struct {bufspec = Raw.allocate_bufferspec (); ctype = None; tag; passable=true}
      
    let ensure_unsealed = function
      | {ctype=None} -> ()
      | _            -> raise ModifyingSealedType

    let seal (Struct s) =
      ensure_unsealed s;
      s.ctype <- Some (Raw.complete_struct_type s.bufspec)

    let ( *:* ) : 'a 's. 's structure typ -> 'a typ -> ('a, 's) field
      = fun (type b) (Struct ({bufspec} as s)) (ftype : b typ) -> 
        ensure_unsealed s;
        let add_argument t = Raw.add_argument bufspec t in
        let foffset = match ftype with
          | Void                     -> raise IncompleteType
          | Array (reftype, n)       -> (s.passable <- false;
                                         assert false (* TODO *))
          | Primitive p              -> add_argument p
          | Pointer p                -> add_argument RawTypes.pointer
          | Struct {ctype=None}      -> raise IncompleteType
          | Struct {ctype=Some ctyp;
                    passable}        -> (s.passable <- s.passable && passable;
                                         add_argument ctyp)
          | Union _                  -> (s.passable <- false;
                                         assert false (* TODO *))
          | FunctionPointer _        -> add_argument RawTypes.pointer
        in
        { ftype; foffset }

    let make (type s) (Struct stype as s : s structure typ) =
      { structure = Ptr.allocate s ~count:1 }
                                                                           
    let (@.) (type s) (type a) 
        { structure }
        { ftype=reftype; foffset=pbyte_offset } = 
      { structure with
        pbyte_offset = structure.pbyte_offset + pbyte_offset;
        reftype }

    let (|->) : 'a 's. 's structure ptr -> ('a, 's) field -> 'a ptr =
      fun (type a) (type s)
        { raw_ptr; pbyte_offset; pmanaged }
        { ftype=reftype; foffset } ->
          { reftype; raw_ptr; pbyte_offset=foffset + pbyte_offset; pmanaged }

    let setf s field v = Ptr.((s @. field) := v)
    let getf s field = Ptr.(!(s @. field))

    let addr {structure} = structure
  end

  module Union =
  struct
    type 's t = 's union = { union: 's union ptr }
    type ('a, 's) field  = 'a typ
        
    let tag utag = Union {utag; usize = 0; ualignment = 0; ucomplete = false}

    let ensure_unsealed = function
      | {ucomplete=true} -> raise ModifyingSealedType
      | _ -> ()

    let seal (Union u) = begin
      ensure_unsealed u;
      u.ucomplete <- true
    end

    let ( *:* ) (Union u) ftype =
      begin
        ensure_unsealed u;
        u.usize <- max u.usize (sizeof ftype);
        u.ualignment <- max u.ualignment (alignment ftype);
        ftype
      end

    let make t = { union = Ptr.allocate t ~count:1 }
    let (@.) {union} reftype = {union with reftype}
    let (|->) p reftype = {p with reftype}
    let setf s field v = Ptr.((s @. field) := v)
    let getf s field = Ptr.(!(s @. field))
    let addr {union} = union
  end

  module Type =
  struct
    type 'a t = 'a typ
    type 'a f = 'a fn

    let void = Void
    let char = Primitive RawTypes.char
    let float = Primitive RawTypes.float
    let double = Primitive RawTypes.double
    let int = Primitive RawTypes.int
    let nativeint = Primitive RawTypes.nativeint
    let int8_t = Primitive RawTypes.int8_t
    let short = Primitive RawTypes.short
    let int16_t = Primitive RawTypes.int16_t
    let int32_t = Primitive RawTypes.int32_t
    let int64_t = Primitive RawTypes.int64_t
    let uchar = Primitive RawTypes.uchar
    let uint8_t = Primitive RawTypes.uint8_t
    let uint16_t = Primitive RawTypes.uint16_t
    let uint32_t = Primitive RawTypes.uint32_t
    let uint64_t = Primitive RawTypes.uint64_t
    let size_t = Primitive RawTypes.size_t
    let ushort = Primitive RawTypes.ushort
    let uint = Primitive RawTypes.uint
    let ulong = Primitive RawTypes.ulong
    let ullong = Primitive RawTypes.ullong

    let string = Primitive RawTypes.string

    let array i t = Array (t, i)
    let ptr t = Pointer t
    let ( @->) f t = 
      if not (passable f) then
        raise (Unsupported "Unsupported argument type")
      else
        Function (f, t)

    let returning v = 
      if not (passable v) then
        raise (Unsupported "Unsupported return type")
      else
        Returns (false, v)
    let syscall v = Returns (true, v)
    let funptr f = FunctionPointer f
  end

  let foreign ?from symbol typ =
    let addr = Dl.dlsym ?handle:from ~symbol in
    build_function ~name:symbol typ addr

  let foreign_value ?from symbol reftype =
    let raw_ptr = Dl.dlsym ?handle:from ~symbol in
    { Ptr.reftype ; raw_ptr; pbyte_offset = 0 ; pmanaged=None }
end
