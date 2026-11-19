trigger leadTrigger on Lead (before insert, after insert, before update, after update) {
    if(Trigger.isInsert && Trigger.isBefore){
        System.debug('Before Insert Trigger on Lead');
        LeadTriggerHandler.assignLeadsToAM(trigger.new);
        LeadTriggerHandler.addJtToTitleAndTitleToJt(trigger.new);
    }
    if(Trigger.isUpdate && Trigger.isBefore){
        System.debug('Before Update Trigger on Lead');
        LeadTriggerHandler.addJtToTitleAndTitleToJt(trigger.new);
    }
    if(Trigger.isUpdate && Trigger.isAfter){
        // Converted lead: copy its phone-captured location to the Account if the Account has none
        LeadConvertLocationHandler.copyLocationToAccount(Trigger.new, Trigger.oldMap);
    }
}