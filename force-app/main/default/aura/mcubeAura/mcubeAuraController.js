({
    closeModal: function (component, event, helper) {
        // Navigate to object home — same as complaint cmp closeModal
        var homeEvt = $A.get('e.force:navigateToObjectHome');
        if (homeEvt) {
            homeEvt.setParams({ scope: 'MCube_Configuration__c' });
            homeEvt.fire();
        }
    }
})