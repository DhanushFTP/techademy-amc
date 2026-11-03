trigger contactTrigger on Contact (before insert, after insert, before update, after update) {
    if(Trigger.isInsert && Trigger.isBefore){
        System.debug('Before Insert Trigger on Contact');
        ContactTriggerHandler.assignContactsToAM(trigger.new);
        ContactTriggerHandler.addJtToTitleAndTitleToJt(trigger.new);
    }
    
    if(Trigger.isUpdate && Trigger.isBefore){
        System.debug('Before Update Trigger on Contact');
        ContactTriggerHandler.addJtToTitleAndTitleToJt(trigger.new);
    }
}