#include <errno.h>
#include <assert.h>
#include <string.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/hash.h>
#include <caml/unixsupport.h>

#include <ffi.h>

#include "managed_buffer_stubs.h"
#include "type_info_stubs.h"

/* #include <caml/threads.h> */

/* TODO: support callbacks that raise exceptions?  e.g. using caml_callback_exn etc.  */
/* TODO: thread support (caml_acquire_runtime_system / caml_release_runtime_system)
   (2) As a special case: If you enter/leave_blocking_section() then some
   other thread might (almost certainly will) do an allocation. So any ocaml
   values you need in enter/leave_blocking_section() need to be copied to C
   values beforehand and values you need after need to be protected. */

static value allocate_custom(struct custom_operations *ops, size_t size, void *prototype)
{
  /* http://caml.inria.fr/pub/docs/manual-ocaml-4.00/manual033.html#htoc286 */
  value block = caml_alloc_custom(ops, size, 0, 1);
  void *data = Data_custom_val(block);
  if (prototype != NULL)
  {
    memcpy(data, prototype, size);
  }
  return block;
}


/* null_value : unit -> voidp */
value ctypes_null_value(value unit)
{
  return (value)NULL;
}

static void check_ffi_status(ffi_status status)
{
  switch (status)
  {
  case FFI_OK:
    break;
  case FFI_BAD_TYPEDEF:
    raise_with_string(*caml_named_value("FFI_internal_error"),
                      "FFI_BAD_TYPEDEF");
  case FFI_BAD_ABI:
    raise_with_string(*caml_named_value("FFI_internal_error"),
                      "FFI_BAD_ABI");
  default:
    assert(0);
  }
}

/* Given an offset into a fully-aligned buffer, compute the next
   offset that satisfies `alignment'. */
static size_t aligned_offset(size_t offset, size_t alignment)
{
  return offset + (offset % alignment);
}

/* A description of a typed buffer.  The bufferspec type serves a dual
   purpose: it describes the buffer used to hold the arguments that we
   pass to C functions via ffi_call, and it describes the layout of
   structs.
*/
static struct bufferspec {
  /* The ffi_cif structure holds the information that we're
     maintaining here, but it isn't part of the public interface. */

  /* The space needed to store properly-aligned arguments and return
     value. */
  size_t bytes;

  /* The number of elements. */
  size_t nelements;

  /* The capacity of the args array, including the terminating null. */
  size_t capacity;

  /* The maximum element alignment */
  size_t max_align;

  /* The state of the bufferspec value. */
  enum { BUILDING,
         BUILDING_UNPASSABLE,
         STRUCTSPEC,
         STRUCTSPEC_UNPASSABLE,
         CALLSPEC } state;

  /* A null-terminated array of size `nelements' types */
  ffi_type **args;

} bufferspec_prototype = {
  0, 0, 0, 0, BUILDING, NULL,
};

static struct callspec {
  struct bufferspec bufferspec;

  /* return value offset */
  size_t roffset;

  /* The libffi call interface structure. */
  ffi_cif cif;
} callspec_prototype = {
  { 0, 0, 0, 0, BUILDING, NULL }, -1,
};

void finalize_bufferspec(value v)
{
  struct bufferspec *bufferspec = Data_custom_val(v);
  free(bufferspec->args);
}


static int compare_bufferspecs(value l_, value r_)
{
  struct bufferspec *lti = Data_custom_val(l_);
  struct bufferspec *rti = Data_custom_val(r_);

  intptr_t l = (intptr_t)&lti->args;
  intptr_t r = (intptr_t)&rti->args;
  return (l > r) - (l < r);
}


static long hash_bufferspec(value v)
{
  struct bufferspec *bufferspec = Data_custom_val(v);

  return bufferspec->args != NULL
    ? caml_hash_mix_int64(0, (uint64)bufferspec->args)
    : 0;
}


static struct custom_operations bufferspec_custom_ops = {
  "ocaml-ctypes:bufferspec",
  finalize_bufferspec,
  compare_bufferspecs,
  hash_bufferspec,
  /* bufferspec objects are not serializable */
  custom_serialize_default,
  custom_deserialize_default
};

/* We store two things in the callbuffer: a "scratch" area for passing
   arguments and receiving the return value, and an array of pointers into the
   scratch area; we pass that array to ffi_call along with a pointer to the
   return value space.

   The scratch area comes first, followed by the pointer array.

   The incomplete struct type gives a modicum of type safety over void *: the
   compiler should reject incompatible assignments, for example.
 */
typedef struct callbuffer callbuffer;

/* [TODO]: document. */
static size_t compute_arg_buffer_size(struct bufferspec *bufferspec, size_t *arg_array_offset)
{
  assert(bufferspec->state == CALLSPEC);

  size_t bytes = bufferspec->bytes;

  size_t callbuffer_size = bytes;
  *arg_array_offset = aligned_offset(bytes, ffi_type_pointer.alignment);
  bytes = *arg_array_offset + bufferspec->nelements * sizeof(void *);

  return bytes;
}

/* [TODO]: document. */
static void populate_callbuffer(struct bufferspec *bufferspec, callbuffer *buf, size_t bytes, size_t arg_array_offset)
{
  void **arg_array = (void **)((char *)buf + arg_array_offset);
  size_t i = 0, offset = 0;
  for (; i < bufferspec->nelements; i++)
  {
    offset = aligned_offset(offset, bufferspec->args[i]->alignment);
    arg_array[i] = (char *)buf + offset;
    offset += bufferspec->args[i]->size;
  }
}


/* Allocate a new C buffer specification */
/* allocate_buffer : unit -> bufferspec */
value ctypes_allocate_bufferspec(value unit)
{
  return allocate_custom(&bufferspec_custom_ops,
                         sizeof(struct bufferspec),
                         &bufferspec_prototype);
}

/* Allocate a new C call specification */
/* allocate_callspec : unit -> callspec */
value ctypes_allocate_callspec(value unit)
{
  return allocate_custom(&bufferspec_custom_ops,
                         sizeof(struct callspec),
                         &bufferspec_prototype);
}


static int ctypes_add_unpassable_argument_(struct bufferspec *bufferspec, int size, int alignment)
{
  assert(bufferspec->state == BUILDING
      || bufferspec->state == BUILDING_UNPASSABLE);

  bufferspec->state = BUILDING_UNPASSABLE;
  free(bufferspec->args);
  bufferspec->args = NULL;

  int offset = aligned_offset(bufferspec->bytes, alignment);
  bufferspec->bytes = offset + size;

  bufferspec->nelements += 1;
  bufferspec->max_align = alignment > bufferspec->max_align
    ? alignment
    : bufferspec->max_align;
  
  return offset;
}

/* Add a struct element to the C call specification using only size and alignment information */
/* add_unpassable_argument : bufferspec -> size:int -> alignment:int -> int */
value ctypes_add_unpassable_argument(value bufferspec_, value size_, value alignment_)
{
  CAMLparam3(bufferspec_, size_, alignment_);
  struct bufferspec *bufferspec = Data_custom_val(bufferspec_);
  int size = Int_val(size_);
  int alignment = Int_val(alignment_);

  CAMLreturn(Val_int(ctypes_add_unpassable_argument_(bufferspec, size, alignment))); 
}


/* Add an argument to the C call specification */
/* add_argument : bufferspec -> 'a ctype -> int */
value ctypes_add_argument(value bufferspec_, value argument_)
{
  static const size_t increment_size = 8;

  CAMLparam2(bufferspec_, argument_);
  struct bufferspec *bufferspec = Data_custom_val(bufferspec_);
  ffi_type *argtype = (((struct type_info *)Data_custom_val(argument_)))->ffitype;

  switch (bufferspec->state) {

  case BUILDING: {
    /* If there's a possibility that this spec represents an argument list or
       a struct we might pass by value then we have to take care to maintain
       the args, capacity and nelements members. */
    int offset = aligned_offset(bufferspec->bytes, argtype->alignment);
    bufferspec->bytes = offset + argtype->size;

    if (bufferspec->nelements + 2 >= bufferspec->capacity) {
      size_t new_size = (bufferspec->capacity + increment_size) * sizeof *bufferspec->args;
      void *temp = realloc(bufferspec->args, new_size);
      if (temp == NULL) {
        caml_raise_out_of_memory();
      }
      bufferspec->args = temp;
      bufferspec->capacity += increment_size;
    }
    bufferspec->args[bufferspec->nelements] = argtype;
    bufferspec->args[bufferspec->nelements + 1] = NULL;
    bufferspec->nelements += 1;
    bufferspec->max_align = argtype->alignment > bufferspec->max_align
      ? argtype->alignment
      : bufferspec->max_align;
    CAMLreturn(Val_int(offset));
  }
  case BUILDING_UNPASSABLE: {
    /* If this spec represents an unpassable struct then we can ignore the
       args, capacity and nelements members. */
    int offset = ctypes_add_unpassable_argument_
               (bufferspec,
                argtype->size,
                argtype->alignment);

    CAMLreturn(Val_int(offset));
  }
  default: {
    assert(0);
  }
  }
}


/* Pass the return type and conclude the specification preparation */
/* prep_callspec : bufferspec -> 'a ctype -> unit */
value ctypes_prep_callspec(value callspec_, value rtype)
{
  CAMLparam2(callspec_, rtype);

  struct callspec *callspec = Data_custom_val(callspec_);
  ffi_type *rffitype = (((struct type_info *)Data_custom_val(rtype)))->ffitype;

  /* Add the (aligned) space needed for the return value */
  callspec->roffset = aligned_offset(callspec->bufferspec.bytes, rffitype->alignment);
  callspec->bufferspec.bytes = callspec->roffset + rffitype->size;

  /* Allocate an extra word after the return value space to work
     around a bug in libffi which causes it to write past the return
     value space.

        https://github.com/atgreen/libffi/issues/35
  */
  callspec->bufferspec.bytes = aligned_offset(callspec->bufferspec.bytes, ffi_type_pointer.alignment);
  callspec->bufferspec.bytes += ffi_type_pointer.size;

  ffi_status status = ffi_prep_cif(&callspec->cif,
                                   FFI_DEFAULT_ABI,
                                   callspec->bufferspec.nelements,
                                   rffitype,
                                   callspec->bufferspec.args);

  check_ffi_status(status);

  callspec->bufferspec.state = CALLSPEC;
  CAMLreturn(Val_unit);
}

/* Call the function specified by `callspec', passing arguments and return
   values in `buffer' */
/* call' : voidp -> callspec -> (buffer -> unit) -> (buffer -> 'a) -> 'a */
value ctypes_call(value function, value callspec_, value argwriter, value rvreader)
{
  CAMLparam4(function, callspec_, argwriter, rvreader);

  void (*cfunction)(void) = (void (*)(void))(void *)function;
  struct callspec *callspec = Data_custom_val(callspec_);
  struct bufferspec *bufferspec = (struct bufferspec *)callspec;
  int roffset = callspec->roffset;

  assert(bufferspec->state == CALLSPEC);

  size_t arg_array_offset;
  size_t bytes = compute_arg_buffer_size(bufferspec, &arg_array_offset);

  char *buffer = alloca(bytes);
  char *return_slot = buffer + roffset;

  populate_callbuffer(bufferspec, (struct callbuffer *)buffer, bytes, arg_array_offset);

  caml_callback(argwriter, (value)buffer);

  ffi_call(&callspec->cif,
           cfunction,
           return_slot,
           (void **)(buffer + aligned_offset(bufferspec->bytes, ffi_type_pointer.alignment)));

  CAMLreturn(caml_callback(rvreader, (value)return_slot));
}

value ctypes_call_errno(value fnname, value function, value callspec_, value argwriter, value rvreader)
{
  CAMLparam5(fnname, function, callspec_, argwriter, rvreader);
  
  errno = 0;
  CAMLlocal1(rv);
  rv = ctypes_call(function, callspec_, argwriter, rvreader);
  if (errno != 0)
  {
    char *buffer = alloca(caml_string_length(fnname) + 1);
    strcpy(buffer, String_val(fnname));
    unix_error(errno, buffer, Nothing);
  }
  CAMLreturn(rv);
}


typedef struct closure closure;
struct closure
{
  ffi_closure closure;
  value       fn;
};

enum boxedfn_tags { Done, Fn };

static void callback_handler(ffi_cif *cif,
                             void *ret,
                             void **args,
                             void *user_data_)
{
  int arity = cif->nargs;

  value *user_data = user_data_;

  CAMLlocal1(boxedfn);
  boxedfn = *user_data;

  int i;
  for (i = 0; i < arity; i++)
  {
    void *cvalue = args[i];
    assert (Tag_val(boxedfn) == Fn);
    /* unbox and call */
    boxedfn = caml_callback(Field(boxedfn, 0), (value)cvalue);
  }

  /* now store the return value */
  assert (Tag_val(boxedfn) == Done);
  caml_callback(Field(boxedfn, 0), (value)ret);
}


/* Construct a pointer to a boxed n-ary function */
/* make_function_pointer : callspec -> boxedfn -> voidp */
value ctypes_make_function_pointer(value callspec_, value boxedfn)
{
  CAMLparam2(callspec_, boxedfn);
  struct callspec *callspec = Data_custom_val(callspec_);

  assert(callspec->bufferspec.state == CALLSPEC);

  void (*code_address)(void) = NULL;

  closure *closure = ffi_closure_alloc(sizeof *closure,
                                       (void *)&code_address);

  if (closure == NULL) {
    caml_raise_out_of_memory();
  }
  else {
    closure->fn = boxedfn;
   /* TODO: what should be the lifetime of OCaml functions passed to C
      (ffi_closure objects) When can we call ffi_closure_free and
      caml_unregister_generational_global_root? */
    caml_register_generational_global_root(&(closure->fn));

    ffi_status status =  ffi_prep_closure_loc
      ((ffi_closure *)closure,
       &callspec->cif,
       callback_handler,
       &closure->fn,
       (void *)code_address);

    check_ffi_status(status);

    CAMLreturn ((value)(void *)code_address);
  }
}


/* _complete_struct_type : callspec -> _ctype */
value ctypes_complete_structspec(value bufferspec_)
{
  CAMLparam1(bufferspec_);

  struct bufferspec *bufferspec = Data_custom_val(bufferspec_);

  CAMLlocal1(block);
  block = ctypes_allocate_struct_type_info(bufferspec->args);
  struct type_info *t = Data_custom_val(block);

  switch (bufferspec->state) {
  case BUILDING: {
    /* We'll use prep_ffi_cif to trigger computation of the size and alignment
       of the struct type rather than repeating what's already in libffi.  It'd
       be nice if the initialize_aggregate function were exposed so that we
       could do without the dummy cif.
    */
    ffi_cif _dummy_cif;
    ffi_status status = ffi_prep_cif(&_dummy_cif, FFI_DEFAULT_ABI, 0, t->ffitype, NULL);

    check_ffi_status(status);

    bufferspec->state = STRUCTSPEC;

    CAMLreturn(block);
  }
  case BUILDING_UNPASSABLE: {
    /* Compute padding, and populate the size and alignment fields.  The other
       components, including the args array, are ignored altogether */
    t->ffitype->size = aligned_offset(bufferspec->bytes, bufferspec->max_align);
    t->ffitype->alignment = bufferspec->max_align;
    CAMLreturn(block);

    bufferspec->state = STRUCTSPEC_UNPASSABLE;
  }
  default: {
    assert (0);
  }
  }
}

/* pointer_plus : char* -> int -> char* */
value ctypes_pointer_plus(value ptr, value i)
{
  /* TODO: we should perhaps check that the result is word-aligned */
  return (value)(((char*)ptr) + Int_val(i));
}


/* memcpy : dest:immediate_pointer -> dest_offset:int ->
            src:immediate_pointer -> src_offset:int ->
            size:int -> unit */
value ctypes_memcpy(value dst, value dst_offset,
                    value src, value src_offset, value size)
{
  CAMLparam5(dst, dst_offset, src, src_offset, size);
  memcpy((char *)dst + Int_val(dst_offset),
         (void *)src + Int_val(src_offset),
         Int_val(size));
  CAMLreturn(Val_unit);
}
