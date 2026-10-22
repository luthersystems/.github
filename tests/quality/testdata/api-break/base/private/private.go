// Package private stands for a private module CI cannot fetch, such as
// substrate's license module. The tests pass it in exclude-deps.
package private

// Key is exported so the package has an API.
func Key() string { return "k" }
