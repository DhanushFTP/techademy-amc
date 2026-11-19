/**
 * @description  Handles deal alert emails for Opportunity inserts and updates: evaluates the
 *               alert rules, builds the emails and sends them in bulk-safe batches.
 *               Called from OpportunityTrigger (after insert and after update).
 *
 *               A deal is Won when its Forecast Category moves into Closed and Lost when it
 *               moves into Omitted (the Forecast Category the forecast sheet uses). Moves between
 *               Won stages or between Lost stages, and any change to a deal that stays Won or
 *               Lost, send nothing.
 *
 *               Alert rules and the custom label holding each rule's recipients
 *               (comma/semicolon separated for multiple addresses):
 *                 1. Open deal whose amount crosses 25 Lakhs (rises to 25 Lakhs or above, or drops
 *                    below it), or deal created at 25 Lakhs or above. Also a Won / Lost deal of
 *                    25 Lakhs or above
 *                      -> Opportunity_Alert_High_Value_Emails
 *                 2. Deal of 10 Lakhs or above moved to Won or Lost
 *                      -> Opportunity_Alert_Closed_Won_10L_Emails
 *                 3. Deal moved to Won or Lost (any amount), or created as Won
 *                      -> Opportunity_Alert_Closed_Deal_Emails
 *               Stage changes on an open deal, and amount changes that stay above or below
 *               25 Lakhs, send nothing.
 *               Rules apply only to deals whose owner's line of business is B2B (LOB__c).
 *               When several rules match, one email is sent per deal to the combined recipients.
 *               Each sent email is logged as an email activity on the deal. An alert that could
 *               not be sent or logged is recorded as a completed task on the deal.
 *
 * @author       Tharun N
 * @date         28-09-2026
 * @group        Opportunity
 */
public class OpportunityAlertEmailHandler {

    // Amount thresholds (INR)
    private static final Decimal HIGH_VALUE_THRESHOLD = 2500000; // 25 Lakhs
    private static final Decimal CLOSED_DEAL_THRESHOLD = 1000000; // 10 Lakhs

    // Forecast Categories (ForecastCategoryName) of a Won / Lost deal
    private static final String FORECAST_WON = 'Closed';
    private static final String FORECAST_LOST = 'Omitted';

    // Owner line of business (Opportunity.LOB__c = owner's User.LOB__c) that receives alerts
    private static final String ALERT_LOB = 'B2B';

    // Won stages (Forecast Category Closed). Alerts use the Forecast Category; this list is
    // used by AccountBusinessTypeHandler
    public static final Set<String> STAGES_WON = new Set<String>{
        'Invoiced', 'Invoiced - Delivery Pending', 'Invoiced - Delivery in Progress', 'Overdue', 'Collected'
    };

    // Max emails passed to a single Messaging.sendEmail call
    @TestVisible
    private static final Integer EMAILS_PER_SEND = 100;

    // Prevents duplicate emails when the trigger re-fires in the same transaction (Flows / field updates)
    private static Set<Id> processedOppIds = new Set<Id>();

    // Limit usage after the last run. Usage only drops when Salesforce rolls back and retries a
    // partial-success save (Data Loader / API), so a drop means processedOppIds must be cleared.
    @TestVisible
    private static Integer emailInvocationsSnapshot = 0;
    @TestVisible
    private static Integer dmlStatementsSnapshot = 0;

    // Number of Messaging.sendEmail calls made in this transaction (used by tests)
    @TestVisible
    private static Integer sendInvocationCount = 0;

    // Number of alert emails sent / alerts recorded as failed in this transaction (used by tests)
    @TestVisible
    private static Integer sentEmailCount = 0;
    @TestVisible
    private static Integer failedAlertCount = 0;

    // EmailMessage.Status value for a sent email
    private static final String EMAIL_STATUS_SENT = '3';

    // Org-wide "From" address (cached per transaction)
    private static OrgWideEmailAddress orgWideEmail;
    private static Boolean orgWideEmailLoaded = false;

    /**
     * @description Pairs an alert email with the deal it belongs to, so the email can be
     *              logged as an activity on that deal after it is sent.
     */
    @TestVisible
    private class AlertEmail {
        @TestVisible Id opportunityId;
        @TestVisible Messaging.SingleEmailMessage message;
        // Why the alert could not be sent or logged (null when there was no problem)
        @TestVisible String failureReason;

        AlertEmail(Id opportunityId, Messaging.SingleEmailMessage message) {
            this.opportunityId = opportunityId;
            this.message = message;
        }
    }

    /**
     * @description Entry point from OpportunityTrigger (after insert). Builds the alert
     *              emails for the new deals, sends them in bulk and logs each sent email as
     *              an email activity on its deal.
     * @param newOpps Trigger.new - inserted Opportunity records
     */
    public static void handleAfterInsert(List<Opportunity> newOpps) {
        processAlerts(newOpps, null);
    }

    /**
     * @description Entry point from OpportunityTrigger (after update). Builds the alert
     *              emails for the updated deals, sends them in bulk and logs each sent
     *              email as an email activity on its deal.
     * @param newOpps   Trigger.new - updated Opportunity records
     * @param oldOppMap Trigger.oldMap - Opportunity records before the update
     */
    public static void handleAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap) {
        if (oldOppMap == null) return;
        processAlerts(newOpps, oldOppMap);
    }

    /**
     * @description Builds and sends the alert emails, then records the limit usage used to
     *              detect a retried save.
     * @param newOpps   Inserted or updated Opportunity records
     * @param oldOppMap Opportunity records before the update (null for inserted deals)
     */
    private static void processAlerts(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap) {
        sendEmailsInBulk(buildAlertEmails(newOpps, oldOppMap));
        emailInvocationsSnapshot = Limits.getEmailInvocations();
        dmlStatementsSnapshot = Limits.getDmlStatements();
    }

    // ---------------- Rule evaluation ----------------

    /**
     * @description Evaluates the alert rules for each inserted or updated Opportunity and
     *              builds one email per matching deal. Does not send the emails.
     * @param newOpps   Inserted or updated Opportunity records
     * @param oldOppMap Opportunity records before the update (null for inserted deals)
     * @return List of alert emails ready to be sent (empty if no rule matched)
     */
    @TestVisible
    private static List<AlertEmail> buildAlertEmails(
        List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap
    ) {
        List<AlertEmail> emails = new List<AlertEmail>();
        if (newOpps == null || newOpps.isEmpty()) return emails;

        // A partial-success save was rolled back and is being retried: the emails of the first
        // attempt were discarded, so the deals must be evaluated again
        if (Limits.getEmailInvocations() < emailInvocationsSnapshot || Limits.getDmlStatements() < dmlStatementsSnapshot) {
            processedOppIds.clear();
        }

        // Recipients for each rule, configured in custom labels
        List<String> highValueEmails = parseEmails(System.Label.Opportunity_Alert_High_Value_Emails);
        List<String> closedWon10LEmails = parseEmails(System.Label.Opportunity_Alert_Closed_Won_10L_Emails);
        List<String> closedDealEmails = parseEmails(System.Label.Opportunity_Alert_Closed_Deal_Emails);
        // Base URL of the current org, so deal links open in the same org (sandbox or production)
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();

        for (Opportunity opp : newOpps) {
            // Null for an inserted deal
            Opportunity oldOpp = oldOppMap == null ? null : oldOppMap.get(opp.Id);
            if ((oldOppMap != null && oldOpp == null) || processedOppIds.contains(opp.Id)) continue;
            // Alerts only for deals owned by B2B users
            if (opp.LOB__c != ALERT_LOB) continue;

            Decimal amount = opp.Amount == null ? 0 : opp.Amount;
            Decimal oldAmount = (oldOpp == null || oldOpp.Amount == null) ? 0 : oldOpp.Amount;
            Boolean isHighValue = amount >= HIGH_VALUE_THRESHOLD;
            Boolean wasHighValue = oldAmount >= HIGH_VALUE_THRESHOLD;
            Boolean isWon = opp.ForecastCategoryName == FORECAST_WON;
            Boolean isLost = opp.ForecastCategoryName == FORECAST_LOST;
            // Won / Lost only when the deal enters the Forecast Category, so moves between Won (or
            // Lost) stages send nothing. A deal created as Won alerts; one created in a Lost stage
            // (e.g. Campaign) does not
            Boolean movedToWon = isWon && (oldOpp == null || oldOpp.ForecastCategoryName != FORECAST_WON);
            Boolean movedToLost = isLost && oldOpp != null && oldOpp.ForecastCategoryName != FORECAST_LOST;
            Boolean movedToWonOrLost = movedToWon || movedToLost;
            // Amount alert only for an open deal whose amount crosses 25 Lakhs either way; a deal
            // created at 25 Lakhs or above counts as crossing
            Boolean crossedHighValue = !isWon && !isLost && isHighValue != wasHighValue;

            Set<String> recipients = new Set<String>();
            List<String> reasons = new List<String>();

            // Rule 1: Open deal crossing 25 Lakhs, or a Won / Lost deal of 25 Lakhs or above
            if (crossedHighValue) {
                recipients.addAll(highValueEmails);
                reasons.add(oldOpp == null ? 'Deal created at 25 Lakhs or above'
                    : isHighValue ? 'Amount reached 25 Lakhs or above' : 'Amount dropped below 25 Lakhs');
            } else if (movedToWonOrLost && isHighValue) {
                recipients.addAll(highValueEmails);
                reasons.add('High value deal (25 Lakhs or above)');
            }
            // Rule 2: Deal of 10 Lakhs or above moved to Won / Lost
            if (movedToWonOrLost && amount >= CLOSED_DEAL_THRESHOLD) {
                recipients.addAll(closedWon10LEmails);
                reasons.add('Deal of 10 Lakhs or above');
            }
            // Rule 3: Any deal moved to Won / Lost
            if (movedToWonOrLost) {
                recipients.addAll(closedDealEmails);
                reasons.add((oldOpp == null ? 'Deal created in ' : 'Deal moved to ') + opp.StageName +
                    ' (Forecast Category ' + opp.ForecastCategoryName + ')');
            }

            if (recipients.isEmpty()) continue;
            processedOppIds.add(opp.Id);

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>(recipients));
            email.setSubject(buildSubject(opp, movedToWon, movedToLost));
            // An inserted deal has no old values, so the deal itself is shown as both old and new
            email.setHtmlBody(buildHtmlBody(opp, oldOpp == null ? opp : oldOpp, reasons, orgUrl));
            // Activity is logged manually (logEmailActivities) since recipients are plain addresses
            email.setSaveAsActivity(false);
            emails.add(new AlertEmail(opp.Id, email));
        }

        // Send from the org-wide address when configured (queried only if there is something to send)
        if (!emails.isEmpty() && getOrgWideEmail() != null) {
            for (AlertEmail alert : emails) {
                alert.message.setOrgWideEmailAddressId(getOrgWideEmail().Id);
            }
        }
        return emails;
    }

    // ---------------- Bulk sending ----------------

    /**
     * @description Sends emails in batches of EMAILS_PER_SEND so bulk updates (Data Loader,
     *              mass edits, integrations) stay within Salesforce email limits.
     *              Successfully sent emails are logged as activities on their deals in one
     *              DML. Failures are recorded on the deals and never block saving them.
     * @param emails Alert emails to send
     */
    @TestVisible
    private static void sendEmailsInBulk(List<AlertEmail> emails) {
        if (emails == null || emails.isEmpty()) return;

        // Check the daily single-email limit up front; if exceeded, skip sending instead of failing the save
        try {
            Messaging.reserveSingleEmailCapacity(countRecipients(emails));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Opportunity alert emails skipped - email not permitted or daily limit reached: ' + e.getMessage());
            markFailed(emails, 'Email not sent - email not permitted or daily limit reached: ' + e.getMessage());
            logFailedAlerts(emails);
            return;
        }

        List<AlertEmail> sentEmails = new List<AlertEmail>();
        List<AlertEmail> failedEmails = new List<AlertEmail>();
        List<AlertEmail> batch = new List<AlertEmail>();
        for (AlertEmail alert : emails) {
            batch.add(alert);
            if (batch.size() == EMAILS_PER_SEND) {
                sendBatch(batch, sentEmails, failedEmails);
                batch = new List<AlertEmail>();
            }
        }
        if (!batch.isEmpty()) {
            sendBatch(batch, sentEmails, failedEmails);
        }

        sentEmailCount += sentEmails.size();
        failedEmails.addAll(logEmailActivities(sentEmails));
        logFailedAlerts(failedEmails);
    }

    /**
     * @description Sends one batch of emails, respecting the per-transaction
     *              Messaging.sendEmail invocation limit. Uses allOrNothing = false so one
     *              bad address does not stop the rest of the batch.
     * @param batch  Alert emails to send in a single Messaging.sendEmail call
     * @param sent   Collects the alert emails that were sent successfully
     * @param failed Collects the alert emails that could not be sent
     */
    private static void sendBatch(List<AlertEmail> batch, List<AlertEmail> sent, List<AlertEmail> failed) {
        if (Limits.getEmailInvocations() >= Limits.getLimitEmailInvocations()) {
            System.debug(LoggingLevel.ERROR, 'Opportunity alert emails skipped - sendEmail invocation limit reached. Count: ' + batch.size());
            markFailed(batch, 'Email not sent - sendEmail invocation limit reached in this transaction');
            failed.addAll(batch);
            return;
        }

        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
        for (AlertEmail alert : batch) {
            messages.add(alert.message);
        }

        try {
            sendInvocationCount++;
            // Results are returned in the same order as the messages sent
            List<Messaging.SendEmailResult> results = Messaging.sendEmail(messages, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    sent.add(batch[i]);
                } else {
                    System.debug(LoggingLevel.ERROR, 'Opportunity alert email failed: ' + results[i].getErrors());
                    batch[i].failureReason = 'Email not sent: ' + results[i].getErrors();
                    failed.add(batch[i]);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Opportunity alert email exception: ' + e.getMessage());
            markFailed(batch, 'Email not sent: ' + e.getMessage());
            failed.addAll(batch);
        }
    }

    /**
     * @description Counts the total number of To addresses across all emails
     *              (the unit used by the daily single-email limit).
     */
    private static Integer countRecipients(List<AlertEmail> emails) {
        Integer total = 0;
        for (AlertEmail alert : emails) {
            total += alert.message.getToAddresses() == null ? 0 : alert.message.getToAddresses().size();
        }
        return total;
    }

    // ---------------- Email activity ----------------

    /**
     * @description Logs sent alert emails as email activities (EmailMessage records) on
     *              their deals, so they appear in the Opportunity activity timeline.
     *              Inserted in a single DML with allOrNone = false; failures never block
     *              saving the deals.
     * @param sentEmails Alert emails that were sent successfully
     * @return The alert emails that were sent but could not be logged on their deals
     */
    @TestVisible
    private static List<AlertEmail> logEmailActivities(List<AlertEmail> sentEmails) {
        List<AlertEmail> notLogged = new List<AlertEmail>();
        if (sentEmails == null || sentEmails.isEmpty()) return notLogged;

        OrgWideEmailAddress owea = getOrgWideEmail();
        String fromAddress = owea != null ? owea.Address : UserInfo.getUserEmail();
        String fromName = owea != null ? owea.DisplayName : UserInfo.getName();

        List<EmailMessage> activities = new List<EmailMessage>();
        for (AlertEmail alert : sentEmails) {
            activities.add(new EmailMessage(
                RelatedToId = alert.opportunityId,
                Subject     = alert.message.getSubject(),
                HtmlBody    = alert.message.getHtmlBody(),
                ToAddress   = String.join(alert.message.getToAddresses(), '; '),
                FromAddress = fromAddress,
                FromName    = fromName,
                Status      = EMAIL_STATUS_SENT,
                Incoming    = false,
                MessageDate = System.now()
            ));
        }

        try {
            // Results are returned in the same order as the records inserted
            List<Database.SaveResult> results = Database.insert(activities, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    System.debug(LoggingLevel.ERROR, 'Opportunity alert email activity not logged: ' + results[i].getErrors());
                    sentEmails[i].failureReason = 'Email sent but not saved on the deal: ' + results[i].getErrors();
                    notLogged.add(sentEmails[i]);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Opportunity alert email activity exception: ' + e.getMessage());
            markFailed(sentEmails, 'Email sent but not saved on the deal: ' + e.getMessage());
            notLogged.addAll(sentEmails);
        }
        return notLogged;
    }

    // ---------------- Failed alerts ----------------

    /**
     * @description Sets the failure reason on each of the given alert emails.
     */
    private static void markFailed(List<AlertEmail> emails, String reason) {
        for (AlertEmail alert : emails) {
            alert.failureReason = reason;
        }
    }

    /**
     * @description Records alerts that could not be sent or logged as completed tasks on
     *              their deals, so a missed alert is visible in the Opportunity activity
     *              timeline. Inserted in a single DML with allOrNone = false; failures
     *              never block saving the deals.
     * @param failedEmails Alert emails with their failureReason set
     */
    @TestVisible
    private static void logFailedAlerts(List<AlertEmail> failedEmails) {
        if (failedEmails == null || failedEmails.isEmpty()) return;
        failedAlertCount += failedEmails.size();

        try {
            List<TaskStatus> closedStatus = [SELECT MasterLabel FROM TaskStatus WHERE IsClosed = true LIMIT 1];

            List<Task> tasks = new List<Task>();
            for (AlertEmail alert : failedEmails) {
                Task failure = new Task(
                    WhatId       = alert.opportunityId,
                    Subject      = ('Deal alert email issue: ' + alert.message.getSubject()).left(255),
                    Description  = (alert.failureReason + '\nRecipients: ' + String.join(alert.message.getToAddresses(), '; ')).left(32000),
                    ActivityDate = Date.today()
                );
                if (!closedStatus.isEmpty()) failure.Status = closedStatus[0].MasterLabel;
                tasks.add(failure);
            }

            for (Database.SaveResult result : Database.insert(tasks, false)) {
                if (!result.isSuccess()) {
                    System.debug(LoggingLevel.ERROR, 'Opportunity alert failure not recorded: ' + result.getErrors());
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Opportunity alert failure exception: ' + e.getMessage());
        }
    }

    // ---------------- Email template ----------------

    /**
     * @description Builds the email subject based on the deal outcome.
     * @param opp         Inserted or updated Opportunity
     * @param movedToWon  True if the deal just became Won
     * @param movedToLost True if the deal just became Lost
     * @return Email subject
     */
    private static String buildSubject(Opportunity opp, Boolean movedToWon, Boolean movedToLost) {
        String prefix = movedToWon ? 'Deal Won' : movedToLost ? 'Deal Lost' : 'High Value Deal Update';
        return prefix + ': ' + opp.Name + ' (' + formatLakhs(opp.Amount) + ')';
    }

    /**
     * @description Builds the HTML email body with the alert reasons and deal details.
     * @param opp     Inserted or updated Opportunity
     * @param oldOpp  Opportunity before the update, used to show old -> new values (the deal
     *                itself for an inserted deal)
     * @param reasons Alert reasons that matched for this deal
     * @param orgUrl  Current org base URL used for the deal link
     * @return HTML email body
     */
    private static String buildHtmlBody(Opportunity opp, Opportunity oldOpp, List<String> reasons, String orgUrl) {
        String reasonList = '';
        for (String r : reasons) {
            reasonList += '<li>' + r.escapeHtml4() + '</li>';
        }

        return
            '<div style="font-family:Arial,sans-serif;font-size:14px;color:#333;">' +
            '<p>Hi,</p>' +
            '<p>The following deal requires your attention:</p>' +
            '<ul>' + reasonList + '</ul>' +
            '<table cellpadding="6" cellspacing="0" border="1" style="border-collapse:collapse;border-color:#ddd;">' +
            row('Deal Name', opp.Name) +
            row('Stage', changeText(oldOpp.StageName, opp.StageName)) +
            row('Amount', changeText(formatAmount(oldOpp.Amount), formatAmount(opp.Amount))) +
            row('Close Date', opp.CloseDate == null ? '' : opp.CloseDate.format()) +
            row('Updated By', UserInfo.getName()) +
            '</table>' +
            '<p><a href="' + orgUrl + '/lightning/r/Opportunity/' + opp.Id + '/view">Click here to view the deal</a></p>' +
            '<p>Regards,<br/>Salesforce Notification</p>' +
            '</div>';
    }

    /**
     * @description Builds one HTML table row (label / value), escaping the value.
     */
    private static String row(String label, String value) {
        return '<tr><td style="background:#f3f3f3;"><b>' + label + '</b></td><td>' +
            (value == null ? '' : value.escapeHtml4()) + '</td></tr>';
    }

    /**
     * @description Returns "old → new" when the value changed, otherwise just the value.
     */
    private static String changeText(String oldValue, String newValue) {
        return oldValue == newValue ? newValue : oldValue + ' → ' + newValue;
    }

    /**
     * @description Formats an amount as "INR 30,00,000.00 (30.00 Lakhs)".
     */
    private static String formatAmount(Decimal amount) {
        if (amount == null) return '-';
        return 'INR ' + amount.setScale(2).format() + ' (' + formatLakhs(amount) + ')';
    }

    /**
     * @description Formats an amount in Lakhs, e.g. 2500000 -> "25.00 Lakhs".
     */
    private static String formatLakhs(Decimal amount) {
        if (amount == null) return '0 Lakhs';
        return (amount / 100000).setScale(2).format() + ' Lakhs';
    }

    // ---------------- Utilities ----------------

    /**
     * @description Splits a custom label value into individual email addresses.
     * @param labelValue Comma or semicolon separated email addresses
     * @return List of trimmed, non-blank email addresses
     */
    private static List<String> parseEmails(String labelValue) {
        List<String> emails = new List<String>();
        if (String.isBlank(labelValue)) return emails;
        for (String e : labelValue.split('[,;]')) {
            if (String.isNotBlank(e)) emails.add(e.trim());
        }
        return emails;
    }

    /**
     * @description Looks up the org-wide email address configured in the OrgWideEmailAddressID
     *              label. Queried once per transaction and cached.
     * @return OrgWideEmailAddress record, or null if not configured / not found
     */
    private static OrgWideEmailAddress getOrgWideEmail() {
        if (!orgWideEmailLoaded) {
            orgWideEmailLoaded = true;
            String address = System.Label.OrgWideEmailAddressID;
            if (String.isNotBlank(address)) {
                List<OrgWideEmailAddress> owea = [
                    SELECT Id, Address, DisplayName FROM OrgWideEmailAddress WHERE Address = :address LIMIT 1
                ];
                orgWideEmail = owea.isEmpty() ? null : owea[0];
            }
        }
        return orgWideEmail;
    }
}