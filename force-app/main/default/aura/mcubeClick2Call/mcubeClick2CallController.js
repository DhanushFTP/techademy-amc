({
    /**
     * doInit
     * Fires on component load.
     * Delegates to the helper to fetch phone numbers from the current record
     * via MCubeSoftphoneController.getPhoneNumbers().
     */
    doInit: function (component, event, helper) {
        helper.loadPhoneNumbers(component, event, helper);
    },

    /**
     * handleCall
     * Fired when the agent clicks the "Call" button.
     * Validates that a phone number is selected, then delegates to the helper
     * to publish a dial command via Lightning Message Service.
     */
    handleCall: function (component, event, helper) {
        var selectedPhone = component.get('v.selectedPhone');

        if (!selectedPhone || selectedPhone.trim() === '') {
            helper.showToast(component, 'Error',
                'Please select a phone number to call.', 'error');
            return;
        }

        helper.dialSelectedNumber(component, event, helper);
    },

    /**
     * handleCancel
     * Closes the quick action without placing a call.
     */
    handleCancel: function (component, event, helper) {
        helper.closeQuickAction();
    }
})