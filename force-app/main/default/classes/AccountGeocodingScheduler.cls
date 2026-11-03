public class AccountGeocodingScheduler implements Schedulable, Database.Batchable<SObject>, Database.AllowsCallouts {

    // Schedulable entry point
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new AccountGeocodingScheduler(), 1); // 1 at a time due to callout limits
    }

    // Batch: query accounts needing geocoding
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                   Account_Location__Latitude__s, Account_Location__Longitude__s
            FROM Account
            WHERE Type IN ('College', 'University')
              AND Account_Location__Latitude__s = null
              AND (BillingStreet != null OR BillingCity != null)
        ]);
    }

    // Batch: geocode each account and update
    public void execute(Database.BatchableContext bc, List<Account> accounts) {
        List<String> logLines = new List<String>();
        List<Account> toUpdate = new List<Account>();

        for (Account acc : accounts) {
            String address = buildAddress(acc);
            Map<String, Decimal> coords = geocode(address);

            if (coords == null && String.isNotBlank(acc.Name)) {
                // Fallback: name + city
                String fallback = acc.Name + ', ' + (acc.BillingCity != null ? acc.BillingCity : '') + ', India';
                coords = geocode(fallback);
            }

            if (coords != null) {
                acc.Account_Location__Latitude__s  = coords.get('lat');
                acc.Account_Location__Longitude__s = coords.get('lng');
                toUpdate.add(acc);
                logLines.add('Updated: ' + acc.Name + ' -> (' + coords.get('lat') + ', ' + coords.get('lng') + ')');
            } else {
                logLines.add('Failed: ' + acc.Name + ' | Address: ' + address);
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }

        AccountGeocodingLog__c log = new AccountGeocodingLog__c(
            Log_Text__c = String.join(logLines, '\n'),
            Run_Date__c = System.today()
        );
        insert log;
    }

    // Finish: send email summary
    public void finish(Database.BatchableContext bc) {
        List<AccountGeocodingLog__c> logs = [
            SELECT Log_Text__c FROM AccountGeocodingLog__c
            WHERE Run_Date__c = TODAY ORDER BY CreatedDate ASC
        ];

        Integer updated = 0;
        Integer failed = 0;
        List<String> allLines = new List<String>();
        for (AccountGeocodingLog__c l : logs) {
            if (String.isNotBlank(l.Log_Text__c)) {
                allLines.addAll(l.Log_Text__c.split('\n'));
            }
        }
        for (String line : allLines) {
            if (line.startsWith('Updated:')) updated++;
            if (line.startsWith('Failed:')) failed++;
        }

        String body = 'Nightly Account Geocoding Run - ' + System.today() + '\n\n'
            + 'Summary: ' + updated + ' updated, ' + failed + ' failed\n\n'
            + '-----------------------------------\n'
            + String.join(allLines, '\n');

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ UserInfo.getUserEmail() });
        mail.setSubject('Geocoding Run: ' + updated + ' updated, ' + failed + ' failed - ' + System.today());
        mail.setPlainTextBody(body);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

        // Clean up today's log records
        delete logs;
    }

    // Build full address string
    @TestVisible
    private String buildAddress(Account acc) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(acc.BillingStreet))     parts.add(acc.BillingStreet);
        if (String.isNotBlank(acc.BillingCity))       parts.add(acc.BillingCity);
        if (String.isNotBlank(acc.BillingState))      parts.add(acc.BillingState);
        if (String.isNotBlank(acc.BillingPostalCode)) parts.add(acc.BillingPostalCode);
        parts.add('India');
        return String.join(parts, ', ');
    }

    // Nominatim geocoding callout
    @TestVisible
    private Map<String, Decimal> geocode(String query) {
        try {
            String encoded = EncodingUtil.urlEncode(query, 'UTF-8');
            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://nominatim.openstreetmap.org/search?q=' + encoded + '&format=json&limit=1&countrycodes=in');
            req.setMethod('GET');
            req.setHeader('User-Agent', 'SalesforceGeocodingBot/1.0');
            req.setTimeout(10000);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                List<Object> results = (List<Object>) JSON.deserializeUntyped(res.getBody());
                if (!results.isEmpty()) {
                    Map<String, Object> first = (Map<String, Object>) results[0];
                    return new Map<String, Decimal>{
                        'lat' => Decimal.valueOf(String.valueOf(first.get('lat'))),
                        'lng' => Decimal.valueOf(String.valueOf(first.get('lon')))
                    };
                }
            }
        } catch (Exception e) {
            System.debug('Geocode error for: ' + query + ' - ' + e.getMessage());
        }
        return null;
    }
}