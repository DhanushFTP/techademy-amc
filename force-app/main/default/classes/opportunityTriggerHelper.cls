public class opportunityTriggerHelper {
    public static void updateAmountInWords(List<Opportunity> oppList){
        try{
            List<Opportunity> oppListToUpdate = new List<Opportunity>();
            for(Opportunity oppRec : oppList){
                String AmountString = String.valueOf(Integer.valueOf(oppRec.Amount));
                NumberSystem ns = new NumberSystem();
                ns.selectedValue = 'Indian';
                ns.num = AmountString;
                String amountInWords = ns.NumConvert();
                
                Opportunity oppRecNew = new Opportunity();
                oppRecNew.Id = oppRec.Id;
                oppRecNew.Amount_In_Words__c = amountInWords;
                oppListToUpdate.add(oppRecNew);
            }
            if(!oppListToUpdate.isEmpty()){
                update oppListToUpdate;
            }
        }catch(exception e){
            System.debug('Error Message ==> ' + e.getMessage() + ' at Line Number ==> ' + e.getLineNumber());
        }
    }
}