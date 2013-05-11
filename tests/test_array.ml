open OUnit
open Ffi.C


(*
  Creating multidimensional arrays, and reading and writing elements.
*)
let test_multidimensional_arrays () =
  let open Type in

  (* one dimension *)
  let one = Array.make int 10 in
  
  for i = 0 to Array.length one - 1 do
    one.(i) <- i
  done;

  for i = 0 to Array.length one - 1 do
    assert_equal i one.(i)
  done;

  (* two dimensions *)
  let two = Array.make (array 5 char) 10 in
  let s = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" in

  for i = 0 to 9 do
    for j = 0 to 4 do
      two.(i).(j) <- s.[i + j]
    done
  done;

  for i = 0 to 9 do
    for j = 0 to 4 do
      assert_equal two.(i).(j) s.[i + j]
        ~printer:(String.make 1)
    done
  done;

  (* three dimensions *)
  let three = Array.make (array 2 (array 5 float)) 10 in
  let float = Pervasives.float in

  for i = 0 to 9 do
    for j = 0 to 1 do
      for k = 0 to 4 do
      three.(i).(j).(k) <- float i *. float j -. float k
      done
    done
  done;

  for i = 0 to 9 do
    for j = 0 to 1 do
      for k = 0 to 4 do
        assert_equal three.(i).(j).(k) (float i *. float j -. float k)
          ~printer:string_of_float
      done
    done
  done;

  (* four *)
  let four = Array.make (array 3 (array 2 (array 5 int32_t))) 10 in
  let float = Pervasives.float in

  for i = 0 to 9 do
    for j = 0 to 2 do
      for k = 0 to 1 do
        for l = 0 to 4 do
          four.(i).(j).(k).(l)
          <- Int32.(mul (sub (of_int i) (of_int j)) (add (of_int k) (of_int l)))
        done
      done
    done
  done;

  for i = 0 to 9 do
    for j = 0 to 2 do
      for k = 0 to 1 do
        for l = 0 to 4 do
          assert_equal four.(i).(j).(k).(l)
          Int32.(mul (sub (of_int i) (of_int j)) (add (of_int k) (of_int l)))
            ~printer:Int32.to_string
        done
      done
    done
  done


(*
  Test that creating an array initializes all elements appropriately.
*)
let test_array_initialiation () =
  let open Type in
  let int_array = Array.make int ~initial:33 10 in
  for i = 0 to Array.length int_array - 1 do
    assert_equal 33 int_array.(i)
  done;

  let int_array_array = Array.make (array 10 int) ~initial:int_array 5 in
  for i = 0 to Array.length int_array_array - 1 do
    for j = 0 to Array.length int_array_array.(i) - 1 do
      assert_equal 33 int_array_array.(i).(j)
    done
  done


let suite = "Array tests" >:::
  ["multidimensional arrays" >:: test_multidimensional_arrays;
   "array initialization" >:: test_array_initialiation;
  ]


let _ =
  run_test_tt_main suite
