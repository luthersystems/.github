// Package excluded depends on package private, so with private in
// exclude-deps the gate leaves it out.
package excluded

import "example.com/apibreak/private"

// Use is removed in the "excluded package" case.
func Use() string { return private.Key() }
