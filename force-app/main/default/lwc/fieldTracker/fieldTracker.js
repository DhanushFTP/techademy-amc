import { LightningElement, track }   from 'lwc';
import { getLocationService }        from 'lightning/mobileCapabilities';
import { ShowToastEvent }            from 'lightning/platformShowToastEvent';
import startTracking                 from '@salesforce/apex/LocationTrackingController.startTracking';
import logLocation                   from '@salesforce/apex/LocationTrackingController.logLocation';
import stopTracking                  from '@salesforce/apex/LocationTrackingController.stopTracking';
import getActiveSession              from '@salesforce/apex/LocationTrackingController.getActiveSession';
import getLocationCount              from '@salesforce/apex/LocationTrackingController.getLocationCount';

const INTERVAL_MS = 600000; // 10 minutes

export default class FieldTracker extends LightningElement {
    @track isTracking = false;
    @track isLoading = true;
    @track locationCount = 0;
    @track startTime = null;
    @track elapsedTime = '00:00:00';

    sessionId = null;
    _intervalId = null;
    _elapsedIntervalId = null;
    _visibilityHandler = null;

    connectedCallback() {
        this._checkExistingSession();
        this._setupVisibilityHandler();
    }

    disconnectedCallback() {
        this._clearIntervals();
        if (this._visibilityHandler) {
            document.removeEventListener('visibilitychange', this._visibilityHandler);
        }
    }

    get startTimeFormatted() {
        return this.startTime ? new Date(this.startTime).toLocaleTimeString() : '';
    }

    // ── Check for an existing active session on load ──
    _checkExistingSession() {
        this.isLoading = true;
        getActiveSession()
            .then(session => {
                if (session) {
                    this.sessionId = session.Id;
                    this.startTime = session.Start_Time__c;
                    this.isTracking = true;
                    this._startIntervals();
                    this._refreshLocationCount();
                }
            })
            .catch(err => console.error('Error checking session:', err))
            .finally(() => { this.isLoading = false; });
    }

    // ── Page Visibility: log a point immediately when app comes back to foreground ──
    _setupVisibilityHandler() {
        this._visibilityHandler = () => {
            if (!document.hidden && this.isTracking && this.sessionId) {
                this._captureAndLog();
            }
        };
        document.addEventListener('visibilitychange', this._visibilityHandler);
    }

    // ── Start tracking ──
    handleStart() {
        const ls = getLocationService();
        if (!ls.isAvailable()) {
            return this.showToast('Unavailable', 'Location not supported on this device.', 'warning');
        }

        this.isLoading = true;
        startTracking()
            .then(id => {
                this.sessionId = id;
                this.startTime = new Date().toISOString();
                this.isTracking = true;
                this.locationCount = 0;
                this._startIntervals();
                // Capture first point immediately
                this._captureAndLog();
                this.showToast('Tracking Started', 'Your location is now being tracked.', 'success');
            })
            .catch(error => {
                const msg = error.body?.message || error.message || JSON.stringify(error);
                this.showToast('Error', msg, 'error', 'sticky');
            })
            .finally(() => { this.isLoading = false; });
    }

    // ── Stop tracking ──
    handleStop() {
        if (!this.sessionId) return;

        this.isLoading = true;
        // Capture final location before stopping
        this._captureAndLog()
            .then(() => stopTracking({ sessionId: this.sessionId }))
            .then(() => {
                this._clearIntervals();
                this.isTracking = false;
                this.sessionId = null;
                this.startTime = null;
                this.elapsedTime = '00:00:00';
                this.locationCount = 0;
                this.showToast('Tracking Stopped', 'Your day has been logged.', 'success');
            })
            .catch(error => {
                const msg = error.body?.message || error.message || JSON.stringify(error);
                this.showToast('Error', msg, 'error', 'sticky');
            })
            .finally(() => { this.isLoading = false; });
    }

    // ── Capture GPS and send to Apex ──
    _captureAndLog() {
        const ls = getLocationService();
        if (!ls.isAvailable() || !this.sessionId) {
            return Promise.resolve();
        }

        return ls.getCurrentPosition({ enableHighAccuracy: true })
            .then(({ coords }) => {
                return logLocation({
                    sessionId: this.sessionId,
                    latitude:  coords.latitude,
                    longitude: coords.longitude
                });
            })
            .then(() => {
                this.locationCount++;
            })
            .catch(err => {
                console.error('Location capture error:', err);
            });
    }

    _refreshLocationCount() {
        if (!this.sessionId) return;
        getLocationCount({ sessionId: this.sessionId })
            .then(count => { this.locationCount = count; })
            .catch(err => console.error('Count refresh error:', err));
    }

    // ── Timer intervals ──
    _startIntervals() {
        // Location capture every 10 minutes
        this._intervalId = setInterval(() => {
            this._captureAndLog();
        }, INTERVAL_MS);

        // Elapsed time counter every second
        this._elapsedIntervalId = setInterval(() => {
            this._updateElapsedTime();
        }, 1000);
    }

    _clearIntervals() {
        if (this._intervalId) {
            clearInterval(this._intervalId);
            this._intervalId = null;
        }
        if (this._elapsedIntervalId) {
            clearInterval(this._elapsedIntervalId);
            this._elapsedIntervalId = null;
        }
    }

    _updateElapsedTime() {
        if (!this.startTime) return;
        const diff = Date.now() - new Date(this.startTime).getTime();
        const hours   = Math.floor(diff / 3600000);
        const minutes = Math.floor((diff % 3600000) / 60000);
        const seconds = Math.floor((diff % 60000) / 1000);
        this.elapsedTime =
            String(hours).padStart(2, '0') + ':' +
            String(minutes).padStart(2, '0') + ':' +
            String(seconds).padStart(2, '0');
    }

    showToast(title, message, variant, mode = 'dismissable') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}