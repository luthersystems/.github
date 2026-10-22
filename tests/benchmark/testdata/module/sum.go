// Package benchfixture is a tiny module with one benchmark, so CI can run the
// benchmark actions end to end, as a caller does.
package benchfixture

// Sum adds the numbers from 1 to n.
func Sum(n int) int {
	t := 0
	for i := 1; i <= n; i++ {
		t += i
	}
	return t
}
