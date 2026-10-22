// Package main calls a function with a known, fixed vulnerability
// (GO-2022-1059 in golang.org/x/text v0.3.7), so govulncheck must report it.
package main

import (
	"fmt"

	"golang.org/x/text/language"
)

func main() {
	tags, _, err := language.ParseAcceptLanguage("en-US,en;q=0.9")
	fmt.Println(tags, err)
}
