package envtimeout

import (
	"os"
	"time"

	"github.com/sirupsen/logrus"
)

// MaxDuration is the upper bound for installer timeout overrides from the environment.
const MaxDuration = 3 * time.Hour

// Duration returns defaultVal unless envKey is set to a valid duration in (0, MaxDuration].
func Duration(envKey string, defaultVal time.Duration) time.Duration {
	raw, ok := os.LookupEnv(envKey)
	if !ok || raw == "" {
		return defaultVal
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 || d > MaxDuration {
		logrus.Warnf("ignoring %s=%q: using default %s", envKey, raw, defaultVal)
		return defaultVal
	}
	if d != defaultVal {
		logrus.Infof("Using %s=%s (default %s)", envKey, d, defaultVal)
	}
	return d
}
