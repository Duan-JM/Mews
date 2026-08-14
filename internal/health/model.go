package health

import "time"

const (
	SnapshotVersion         = 1
	TransitionConfirmations = 2
	SnapshotLifetime        = 30 * time.Second
	SnapshotFutureTolerance = 5 * time.Minute
	snapshotRefreshMargin   = 10 * time.Second
	NotificationStaleAfter  = 90 * time.Second
)

type State string

const (
	StateChecking State = "checking"
	StateReady    State = "ready"
	StateDegraded State = "degraded"
	StateBlocked  State = "blocked"
)

type Kind string

const (
	KindConfiguration Kind = "configuration"
	KindFunctional    Kind = "functional"
)

type SocketStatus string

const (
	SocketAvailable    SocketStatus = "available"
	SocketMissing      SocketStatus = "missing"
	SocketUnresponsive SocketStatus = "unresponsive"
	SocketInvalid      SocketStatus = "invalid"
)

type NotificationStatus string

const (
	NotificationsAuthorized    NotificationStatus = "authorized"
	NotificationsDenied        NotificationStatus = "denied"
	NotificationsNotDetermined NotificationStatus = "not_determined"
	NotificationsMissing       NotificationStatus = "missing"
	NotificationsUnreadable    NotificationStatus = "unreadable"
	NotificationsUnknown       NotificationStatus = "unknown"
	NotificationsInvalid       NotificationStatus = "invalid"
	NotificationsStale         NotificationStatus = "stale"
)

type IntegrationObservation struct {
	ID     string
	Name   string
	Status string
	Ready  bool
}

type Observation struct {
	CheckedAt          time.Time
	StoreReady         bool
	SetupConfigured    bool
	RollbackReady      bool
	AppBundleReady     bool
	AppBundlePath      string
	LaunchAgentPresent bool
	LaunchAgentLoaded  bool
	LaunchAgentStatus  string
	Socket             SocketStatus
	Notifications      NotificationStatus
	Integrations       []IntegrationObservation
}

type Capability struct {
	ID               string `json:"id"`
	Name             string `json:"name"`
	Kind             Kind   `json:"kind"`
	State            State  `json:"state"`
	Message          string `json:"message"`
	Recovery         string `json:"recovery,omitempty"`
	TransitionFrom   State  `json:"transition_from,omitempty"`
	TransitionTarget State  `json:"transition_target,omitempty"`
	TransitionCount  int    `json:"transition_count,omitempty"`
}

type Snapshot struct {
	Version      int          `json:"version"`
	State        State        `json:"state"`
	Summary      string       `json:"summary"`
	CheckedAt    time.Time    `json:"checked_at"`
	ValidUntil   time.Time    `json:"valid_until"`
	Capabilities []Capability `json:"capabilities"`
}

func (s Snapshot) HasFailures() bool {
	return s.State != StateReady
}

func (s Snapshot) AffectedCapabilities() []Capability {
	affected := make([]Capability, 0, len(s.Capabilities))
	for index := range s.Capabilities {
		capability := &s.Capabilities[index]
		if capability.State != StateReady {
			affected = append(affected, *capability)
		}
	}
	return affected
}
