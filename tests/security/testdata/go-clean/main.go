// Package main has no dependencies and calls nothing vulnerable, so
// govulncheck and gosec must pass on it.
package main

import "fmt"

func main() {
	fmt.Println("clean")
}
