package health

import (
	"encoding/json"
	"os"
	"time"
)

const notificationFutureTolerance = 5 * time.Minute

type notificationStatusFile struct {
	Status    string    `json:"status"`
	CheckedAt time.Time `json:"checked_at"`
}

func ReadNotificationStatus(path string, now time.Time) NotificationStatus {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return NotificationsMissing
	}
	if err != nil {
		return NotificationsUnreadable
	}

	var state notificationStatusFile
	if err := json.Unmarshal(data, &state); err != nil || state.CheckedAt.IsZero() {
		return NotificationsInvalid
	}
	if state.CheckedAt.After(now.Add(notificationFutureTolerance)) {
		return NotificationsInvalid
	}
	if now.After(state.CheckedAt.Add(NotificationStaleAfter)) {
		return NotificationsStale
	}

	switch state.Status {
	case string(NotificationsAuthorized):
		return NotificationsAuthorized
	case string(NotificationsDenied):
		return NotificationsDenied
	case string(NotificationsNotDetermined):
		return NotificationsNotDetermined
	case string(NotificationsUnknown):
		return NotificationsUnknown
	default:
		return NotificationsInvalid
	}
}
