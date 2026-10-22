// Package main checks every error, so golangci-lint must pass on it.
package main

import (
	"fmt"
	"os"
)

func main() {
	if err := os.Remove("does-not-exist"); err != nil {
		fmt.Println("remove:", err)
	}
}
