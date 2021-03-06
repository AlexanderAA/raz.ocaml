(* 
Matthew A. Hammer (matthew.hammer@colorado.edu).

This is an implementation of the Random Access Zipper (RAZ).  It is
closely based on the OCaml implementation by Kyle Headley, and the
2016 article by Headley and Hammer.

There are some differences with the earlier version:

- This RAZ version places levels, not elements, at the center of the
  zipper's cursor.  It enjoys the invariant that #elements = #levels
  + 1, where #levels >= 1, and #elements >= 0. 

  The chief consequence of this representation is that it captures
  empty sequences with zero elements; the prior version required
  special sentinel elements at the ends to represent an empty
  sequence.  Here, we implement sentinels with levels, not special
  sequence elements.

- This RAZ version uses the OCaml type system to attempt to enforce
  some structural invariants about the presence of levels and trees in
  the zipper.  In particular: 

    * The types enforce that #levels = #elements + 1, across all of
      the Cons cells of the zipper, and its centered cursor level.

    * The types enforce that levels and elements interleave, and that
      a level follows each element, which can play the role of the
      "sentinel" if this element is the last/first one in the
      sequence.

  Note that this enforcement does not cover the invariants for trees,
  only the center of the zipper and its Cons cells.  Perhaps future
  verisons can use refinement types (or stronger dependent types) to
  capture the invariants over trees and tree lists. (Not all of these
  invariants are apparent to me yet).

- We assume, but do not statically enforce, that the unfocused tree
  also has that #levels = #elements + 1.  More work is needed to see
  how focus/unfocus/trim connect the invariant about the full tree to
  that of the trimmed subtrees.

- This version of the RAZ is a little shorter than the prior one:
  The Raz module body consists of ~120 lines 
  (not counting these comments or the module type RAZ).

- Unlike the earlier version, this one is untested / unmeasured. (!)

 *)

module type RAZ = 
  sig
    type 'a tree
    type 'a zip
    type lev    = int
    type dir    = L | R
    type 'a cmd =
      | Insert  of dir * 'a * lev
      | Remove  of dir
      | Replace of dir * 'a
      | Move    of dir
		     
    type 'a cmds = 'a zip -> 'a zip
				    
    val empty  : lev -> 'a zip
    val do_cmd : 'a cmd -> 'a cmds
				      
    val unfocus : 'a zip -> 'a tree
    val focus   : 'a tree -> int -> 'a zip
  end

module Raz : RAZ = struct
  type lev      = int
  type cnt      = int
  type dir      = L | R
  type bin_info = { lev:lev; elm_cnt:cnt }
  type 'a tree  = Bin  of bin_info * 'a tree * 'a tree (* Invariant: Levels of sub-trees are less-or-than-equal-to Bin's level *)
		| Leaf of 'a (* Invariant: There are N+1 Bin nodes in every tree with N leaves. *)
		| Nil (* Unfocused invariant: Exactly two Nils, the leftmost/rightmost terminals of the (unfocused) tree. *)
  type 'a elms  = Cons of 'a * lev * 'a elms (* Invariant: element always followed by a level *)
		| Trees of ('a tree) list    (* Invariant: trees not interposed with elements/levels. trim transforms this list. *)
  type 'a zip   = { left:'a elms; lev:lev; right:'a elms}
		    
  let empty (l:lev) : 'a zip = 
    {left=Trees([]);lev=l;right=Trees([])}
      
  let tree_of_lev (l:lev) : 'a tree = 
    Bin({lev=l;elm_cnt=0},Nil,Nil)
       
  let elm_cnt_of_tree (t:'a tree) : cnt = 
    match t with
    | Bin(bi,_,_) -> bi.elm_cnt
    | Leaf(_)     -> 1
    | Nil         -> 0
		       
  let trim (d:dir) (t:'a elms) : ('a * lev * 'a elms) option =
    match t with
    | Cons(a, lev, elms) -> Some((a, lev, elms))
    | Trees(trees) -> 
       let rec loop (ts:('a tree) list) (st:'a option) : ('a * lev * 'a elms) option =
	 match ts, st with
	 | [],                       _      -> None
	 | Nil::trees,               _      -> loop trees st
	 | Leaf(x)::trees,           None   -> loop trees (Some x)
	 | Leaf(_)::_,               Some _ -> failwith "illegal argument" (* leaf-leaf case: Violates Invariant that elements and levels interleave. *) 
	 | Bin(bi, Nil, Nil)::trees, Some x -> Some(x, bi.lev, Trees(trees))
	 | Bin(bi, l, r)::trees, _          ->
	    match d with L -> loop (l::(tree_of_lev bi.lev :: r :: trees)) st 
		       | R -> loop (r::(tree_of_lev bi.lev :: l :: trees)) st
       in loop trees None
	       
  type 'a cmd =
    | Insert  of dir * 'a * lev
    | Remove  of dir
    | Replace of dir * 'a
    | Move    of dir
  type 'a cmds = 'a zip -> 'a zip
				  
  let do_cmd : 'a cmd -> 'a cmds =
    function
    | Insert (d,a,lev) -> (
      match d with
      | L -> fun z -> {z with left  = Cons(a, lev, z.left )}
      | R -> fun z -> {z with right = Cons(a, lev, z.right)}
    )
    | ( Remove (d) | Replace(d,_) | Move (d) ) as trim_cmd -> (
      fun z ->
      let trimmed = match d with
	| L -> trim L z.left
	| R -> trim L z.right
      in
      match trimmed with
      | None -> z (* do nothing; nothing to remove/replace/move *)
      | Some((elm, lev, rest)) -> (
	match trim_cmd with
	| Insert _ -> failwith "impossible" (* Already handled, above. *)
	| Remove(_) ->
	   (match d with L -> {z with left =rest}  (* Removes elm and lev. *)
		       | R -> {z with right=rest}) (* Removes elm and lev. *)
	| Replace(_, a) ->
	   (match d with L -> {z with left =Cons(a, lev, rest)}  (* Replaces elm with a. *)
		       | R -> {z with right=Cons(a, lev, rest)}) (* Replaces elm with a. *)
	| Move(_) ->
	   (match d with L -> {left =rest; lev=lev; right=Cons(elm,z.lev,z.right)}
		       | R -> {right=rest; lev=lev; left =Cons(elm,z.lev,z.left )})))
								
  let rec append (t1:'a tree) (t2:'a tree) : 'a tree =
    let elm_cnt = (elm_cnt_of_tree t1) + (elm_cnt_of_tree t2) in
    match t1, t2 with
    | Nil, _ -> t2
    | _, Nil -> t1
    | Leaf(_), Leaf(_)       -> failwith "invalid argument" (* leaf-leaf case: Violates invariant that elements and levels interleave. *)
    | Leaf(a), Bin(bi, l, r) -> Bin({lev=bi.lev;elm_cnt=elm_cnt}, append t1 l, r)
    | Bin(bi, l, r), Leaf(a) -> Bin({lev=bi.lev;elm_cnt=elm_cnt}, l, append r t2)
    | Bin(bi1, l1, r1),
      Bin(bi2, l2, r2) -> if bi1.lev >= bi2.lev
			  then Bin({lev=bi1.lev;elm_cnt=elm_cnt}, l1, append r1 t2)
			  else Bin({lev=bi2.lev;elm_cnt=elm_cnt}, append t1 l2, r2)
				  
  let rec tree_of_trees (d:dir) (tree:'a tree) (trees:('a tree)list) : 'a tree =
    match trees with
    | [] -> tree
    | tree2::trees -> 
       match d with
       | L -> tree_of_trees d (append tree tree2) trees
       | R -> tree_of_trees d (append tree2 tree) trees
			    
  let rec tree_of_elms (d:dir) (tree:'a tree) (elms:'a elms) : 'a tree =
    match elms with
    | Trees(trees)       -> tree_of_trees d tree trees
    | Cons(elm,lev,elms) -> 
       match d with
       | L -> tree_of_elms d (append tree (append (Leaf elm) (tree_of_lev lev))) elms
       | R -> tree_of_elms d (append (tree_of_lev lev) (append (Leaf elm) tree)) elms
			   
  let unfocus (z: 'a zip) : 'a tree =
    append (tree_of_elms L Nil                 z.left ) 
	   (tree_of_elms R (tree_of_lev z.lev) z.right)
	   
  let focus (tree:'a tree) (pos:int) : 'a zip =  
    let pos = let n = elm_cnt_of_tree tree in 
	      if pos > n then n else if pos < 0 then 0 else pos
    in
    let rec loop (tree:'a tree) (tsl:('a tree) list) (tsr:('a tree) list) =
      match tree with
      | Nil     -> failwith "invalid argument" (* Violates: #Bins = #Leaves + 1 *)
      | Leaf(x) -> failwith "invalid argument" (* Violates: #Bins = #Leaves + 1 *)
      | Bin(bi,l,r) -> (
	let cl = elm_cnt_of_tree l in
	if pos = cl then {lev=bi.lev; left=Trees(l::tsl); right=Trees(r::tsr)}
	else if pos < cl then loop l     (Bin({lev=bi.lev; elm_cnt=elm_cnt_of_tree r},Nil,l)::tsl) tsr
	else                  loop r tsl (Bin({lev=bi.lev; elm_cnt=cl               },l,Nil)::tsr)
      )
    in loop tree [] []
end
		     
(* 

Count valid instances, for small sizes 0, 1, ..:
 names    a,b,c, ...
 elements x,y,z, ...

Size 0: 
 Seq:    a
 #Trees: 1
 Tree:   Bin(a, Nil, Nil)

Size 1: 
 Seq:    a x b
 #Trees: 1 + 1 = 2

 Tree 1: Bin(b, Bin(a, Nil, Leaf(x)), Nil)
 Tree 2: Bin(a, Nil, Bin(b, Leaf(x), Nil))

Size 2: 
 Seq:    a x b y c
 #Trees: 2 + 1 + 2 = 5

Size 3:
 Seq:    a x b y c z d
 #Trees  5 + 2 + 2 + 5 = 13 

  x    0 1 2 3 4 5 6
Fib x  1 1 2 3 5 8 13
Fib 2x 1 2 5 13
*)
