// Package main drops the error os.Remove returns, so errcheck must fail it.
package main

import "os"

func main() {
	os.Remove("does-not-exist")
}
