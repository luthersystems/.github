// Package lib is a public package: the gate compares its API.
package lib

// Hello is removed in the "removed func" case.
func Hello() string { return "hello" }

// Bye stays in every case.
func Bye() string { return "bye" }
