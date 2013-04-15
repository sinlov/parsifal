#!/bin/bash

rlwrap ocaml -I /usr/lib/ocaml/lwt \
	-I /usr/lib/ocaml/cryptokit \
	-I /home/yeye/dev/parsifal/usrlibocaml/parsifal_core \
	-I /home/yeye/dev/parsifal/usrlibocaml/parsifal_net \
	-I /home/yeye/dev/parsifal/usrlibocaml/parsifal_formats \
	-I /home/yeye/dev/parsifal/usrlibocaml/parsifal_ssl \
	unix.cma nums.cma bigarray.cma lwt.cma cryptokit.cma lwt-unix.cma \
	/home/yeye/dev/parsifal/usrlibocaml/parsifal_{core,net,formats,ssl}/*.cma
