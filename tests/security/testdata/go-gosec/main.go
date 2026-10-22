// Package main runs a command named by its caller, which gosec reports as
// G204 (subprocess launched with variable), so the gosec check must fail.
package main

import (
	"os"
	"os/exec"
)

func main() {
	_ = exec.Command(os.Args[1]).Run()
}
