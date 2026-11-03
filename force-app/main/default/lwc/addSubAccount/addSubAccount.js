import { LightningElement, api, track } from 'lwc';
import { NavigationMixin }             from 'lightning/navigation';
import { CloseActionScreenEvent }      from 'lightning/actions';
import { ShowToastEvent }              from 'lightning/platformShowToastEvent';
import getAccountDetails               from '@salesforce/apex/SubAccountController.getAccountDetails';
import createSubAccount                from '@salesforce/apex/SubAccountController.createSubAccount';

export default class AddSubAccount extends NavigationMixin(LightningElement) {
    _recordId;
    _loaded = false;

    @api
    get recordId() { return this._recordId; }
    set recordId(value) {
        this._recordId = value;
        if (value && !this._loaded) {
            this._loaded = true;
            this.loadAccountDetails();
        }
    }

    @track isLoading           = true;
    @track isReady             = false;
    @track isNotOwner          = false;
    @track isCapturingLocation = false;
    @track isCreating          = false;

    // Form state
    @track parentAccountName = '';
    @track subAccountName    = '';
    @track website           = '';
    @track phone             = '';
    @track latitude          = null;
    @track longitude         = null;

    get locationDisplay() {
        if (this.latitude != null && this.longitude != null) {
            return `Lat: ${Number(this.latitude).toFixed(6)}, Lng: ${Number(this.longitude).toFixed(6)}`;
        }
        return 'No location set';
    }

    // ── Called by the recordId setter once recordId is set by the framework ──
    loadAccountDetails() {
        getAccountDetails({ accountId: this._recordId })
            .then(result => {
                if (!result.isOwner) {
                    this.isNotOwner = true;
                    this.showToast(
                        'Access Denied',
                        'You must be the account owner to add sub-accounts.',
                        'error',
                        'sticky'
                    );
                    return;
                }
                this.parentAccountName = result.name    || '';
                this.website           = result.website || '';
                this.phone             = result.phone   || '';
                this.latitude          = result.latitude  != null ? result.latitude  : null;
                this.longitude         = result.longitude != null ? result.longitude : null;
                this.isReady           = true;
            })
            .catch(error => {
                const msg = error.body?.message || error.message || JSON.stringify(error);
                this.showToast('Error', msg, 'error', 'sticky');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleNameChange(event)    { this.subAccountName = event.target.value; }
    handleWebsiteChange(event) { this.website        = event.target.value; }
    handlePhoneChange(event)   { this.phone          = event.target.value; }

    // ── Override location with device GPS ──
    handleUseCurrentLocation() {
        this.isCapturingLocation = true;
        this._getCurrentPosition()
            .then(({ coords }) => {
                this.latitude  = coords.latitude;
                this.longitude = coords.longitude;
            })
            .catch(error => {
                this.showToast('Location Error', error.message, 'error', 'sticky');
            })
            .finally(() => {
                this.isCapturingLocation = false;
            });
    }

    // ── Create the sub-account ──
    handleCreate() {
        if (!this.subAccountName || !this.subAccountName.trim()) {
            this.showToast('Validation Error', 'Sub Account Name is required.', 'error');
            return;
        }

        this.isCreating = true;
        createSubAccount({
            parentId:       this._recordId,
            subAccountName: this.subAccountName.trim(),
            latitude:       this.latitude,
            longitude:      this.longitude,
            website:        this.website || null,
            phone:          this.phone   || null
        })
            .then(newAccountId => {
                this.showToast('Success', 'Sub account created successfully.', 'success');
                this.dispatchEvent(new CloseActionScreenEvent());
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId:   newAccountId,
                        actionName: 'view'
                    }
                });
            })
            .catch(error => {
                const msg = error.body?.message || error.message || JSON.stringify(error);
                this.showToast('Create Failed', msg, 'error', 'sticky');
                this.isCreating = false;
            });
    }

    // ── GPS helper ──
    _getCurrentPosition() {
        return new Promise((resolve, reject) => {
            if (!navigator.geolocation) {
                reject(new Error('Location is not supported on this device. Please enable location services.'));
                return;
            }
            navigator.geolocation.getCurrentPosition(
                (position) => resolve(position),
                (err) => {
                    let msg = 'Unable to get your location. ';
                    if (err.code === 1) {
                        msg += 'Please allow location access for the Salesforce app in your phone Settings.';
                    } else if (err.code === 2) {
                        msg += 'Location unavailable. Please check GPS is enabled.';
                    } else {
                        msg += 'Request timed out. Please try again.';
                    }
                    reject(new Error(msg));
                },
                { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 }
            );
        });
    }

    showToast(title, message, variant, mode = 'dismissable') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}