// Package events announces what happened.
package events

import "log"

// Emit publishes an event to whoever listens.
func Emit(name, id string) {
	log.Printf("event %s %s", name, id)
}
