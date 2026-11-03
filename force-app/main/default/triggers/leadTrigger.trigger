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
}