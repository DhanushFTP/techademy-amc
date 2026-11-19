/**
 * @description  Tests for LeadConvertLocationHandler: a converted lead's location is copied to the
 *               Account only when the Account has none, and every copy is logged.
 *
 * @author       Tharun N
 * @date         06-11-2026
 * @group        Lead
 */
@IsTest
private class LeadConvertLocationHandlerTest {

    private static final Decimal LEAD_LAT = 12.974468821230008;
    private static final Decimal LEAD_LNG = 77.60175432500743;
    private static final Decimal ACCOUNT_LAT = 12.892157;
    private static final Decimal ACCOUNT_LNG = 77.465362;
    private static final String LOG_POINT = 'Lead Convert Location';

    @TestSetup
    static void setup() {
        insert new List<Account>{
            new Account(Name = 'Convert Test Blank One', Type = 'University'),
            new Account(Name = 'Convert Test Blank Two', Type = 'College'),
            new Account(Name = 'Convert Test Located', Type = 'University',
                Account_Location__Latitude__s = ACCOUNT_LAT, Account_Location__Longitude__s = ACCOUNT_LNG)
        };
        insert new List<Lead>{
            new Lead(LastName = 'Convert Test Lead One', Company = 'Convert Test Company',
                Lead_Geo_Location__Latitude__s = LEAD_LAT, Lead_Geo_Location__Longitude__s = LEAD_LNG),
            new Lead(LastName = 'Convert Test Lead Two', Company = 'Convert Test Company',
                Lead_Geo_Location__Latitude__s = LEAD_LAT, Lead_Geo_Location__Longitude__s = LEAD_LNG),
            new Lead(LastName = 'Convert Test Lead No Geo', Company = 'Convert Test Company')
        };
    }

    @IsTest
    static void locationIsCopiedToAccountWithoutLocation() {
        Id accountId = account('Convert Test Blank One').Id;

        Test.startTest();
        convert(lead('Convert Test Lead One').Id, accountId);
        Test.stopTest();

        Account acc = reload(accountId);
        Assert.isTrue(Math.abs(acc.Account_Location__Latitude__s - LEAD_LAT) < 0.000000000001,
            'Lead latitude copied with all decimals, got ' + acc.Account_Location__Latitude__s);
        Assert.isTrue(Math.abs(acc.Account_Location__Longitude__s - LEAD_LNG) < 0.000000000001,
            'Lead longitude copied with all decimals, got ' + acc.Account_Location__Longitude__s);
        Assert.areEqual(1, logCount('Status: Success'), 'Copy is logged');
    }

    @IsTest
    static void existingAccountLocationIsKept() {
        Id accountId = account('Convert Test Located').Id;

        Test.startTest();
        convert(lead('Convert Test Lead One').Id, accountId);
        Test.stopTest();

        Account acc = reload(accountId);
        Assert.areEqual(ACCOUNT_LAT, acc.Account_Location__Latitude__s, 'Account latitude unchanged');
        Assert.areEqual(ACCOUNT_LNG, acc.Account_Location__Longitude__s, 'Account longitude unchanged');
        Assert.areEqual(0, logCount('Status:'), 'Nothing copied, nothing logged');
    }

    @IsTest
    static void leadWithoutLocationChangesNothing() {
        Id accountId = account('Convert Test Blank One').Id;

        Test.startTest();
        convert(lead('Convert Test Lead No Geo').Id, accountId);
        Test.stopTest();

        Assert.isNull(reload(accountId).Account_Location__Latitude__s, 'Account stays blank');
    }

    @IsTest
    static void severalLeadsConvertedTogether() {
        Id accountOne = account('Convert Test Blank One').Id;
        Id accountTwo = account('Convert Test Blank Two').Id;
        List<Database.LeadConvert> conversions = new List<Database.LeadConvert>{
            leadConvert(lead('Convert Test Lead One').Id, accountOne),
            leadConvert(lead('Convert Test Lead Two').Id, accountTwo)
        };

        Test.startTest();
        List<Database.LeadConvertResult> results = Database.convertLead(conversions);
        Test.stopTest();

        for (Database.LeadConvertResult result : results) {
            Assert.isTrue(result.isSuccess(), 'Conversion succeeded');
        }
        Assert.isNotNull(reload(accountOne).Account_Location__Latitude__s, 'First account filled');
        Assert.isNotNull(reload(accountTwo).Account_Location__Latitude__s, 'Second account filled');
        Assert.areEqual(2, logCount('Status: Success'), 'One log row per account');
    }

    @IsTest
    static void updateWithoutConversionDoesNothing() {
        Lead ld = lead('Convert Test Lead One');

        Test.startTest();
        update new Lead(Id = ld.Id, Company = 'Convert Test Company Renamed');
        Test.stopTest();

        Assert.areEqual(0, logCount('Status:'), 'Not converted: nothing copied');
    }

    // ── Helpers ──

    private static void convert(Id leadId, Id accountId) {
        Database.LeadConvertResult result = Database.convertLead(leadConvert(leadId, accountId));
        Assert.isTrue(result.isSuccess(), 'Conversion succeeded');
    }

    private static Database.LeadConvert leadConvert(Id leadId, Id accountId) {
        LeadStatus converted = [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1];
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(leadId);
        lc.setAccountId(accountId);
        lc.setConvertedStatus(converted.MasterLabel);
        lc.setDoNotCreateOpportunity(true);
        return lc;
    }

    private static Lead lead(String lastName) {
        return [SELECT Id FROM Lead WHERE LastName = :lastName LIMIT 1];
    }

    private static Account account(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1];
    }

    private static Account reload(Id accountId) {
        return [
            SELECT Account_Location__Latitude__s, Account_Location__Longitude__s
            FROM Account
            WHERE Id = :accountId
        ];
    }

    // Long text area cannot be filtered in SOQL, so the match is done here
    private static Integer logCount(String contains) {
        Integer count = 0;
        for (lcon__Error_Message_Handler__c log : [
            SELECT lcon__Error_Message__c FROM lcon__Error_Message_Handler__c
            WHERE lcon__Error_Point__c = :LOG_POINT
        ]) {
            if (log.lcon__Error_Message__c != null && log.lcon__Error_Message__c.contains(contains)) {
                count++;
            }
        }
        return count;
    }
}