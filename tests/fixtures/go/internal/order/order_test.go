package order

import (
	"context"
	"testing"
)

type fakeRepo struct{ saved []Order }

func (f *fakeRepo) Save(_ context.Context, o Order) error {
	f.saved = append(f.saved, o)
	return nil
}

func TestProcess(t *testing.T) {
	repo := &fakeRepo{}
	o := Order{ID: "o-1", Items: []Item{{SKU: "tea", Price: 400, Qty: 2}}}
	if err := Process(context.Background(), repo, o, 10); err != nil {
		t.Fatal(err)
	}
	if got := repo.saved[0].Total; got != 720 {
		t.Fatalf("total = %d, want 720", got)
	}
}
