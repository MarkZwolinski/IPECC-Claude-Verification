/init

save all my prompts to prompts.md

analyze the hdl folder. I want to build a testbench for the hdl code. Ignore the existing testbench in sim for now.

Output token limit hit. Resume directly — no apology, no recap of what you were doing. Pick up mid-thought if that is where the cut happened. Break remaining work into smaller pieces.

save my prompts to prompts.md. Save my prompts continuously

Are all the necessary tools installed on this machine?

run the tests with a smaller nn to speed up simulation

wait for the simulation to finish

update prompts.md

write a summary of this session to summary.md

commit

git remote add origin https://github.com/MarkZwolinski/IPECC-Claude-Verification.git
git branch -M main
git push -u origin main

install ghdl-llvm

update the Makefile to use ghdl-llvm

what is the latest version of vhdl supported by ghdl-llvm

update the Makefile to use --std=08

commit

push

update prompts.md including all sessions

commit and push

update summary.md

run the tests

commit and push

add tb/work/ and tb/tb_ecc to .gitignore

update prompts.md
