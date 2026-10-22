package benchfixture

import "testing"

func BenchmarkSum(b *testing.B) {
	for b.Loop() {
		_ = Sum(1000)
	}
}
