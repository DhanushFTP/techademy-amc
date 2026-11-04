/**
 * @description  Handles deal alert emails for Opportunity updates: evaluates the alert
 *               rules, builds the emails and sends them in bulk-safe batches.
 *               Called from OpportunityTrigger (after update).
 *
 *               Alert rules (evaluated on update) and the custom label holding each rule's
 *               recipients (comma/semicolon separated for multiple addresses):
 *                 1. Amount >= 25 Lakhs (before or after the change) and Stage or Amount changed
 *                      -> Opportunity_Alert_High_Value_Emails
 *                 2. Amount >= 10 Lakhs and Stage changed to a Won or Lost stage
 *                      -> Opportunity_Alert_Closed_Won_10L_Emails
 *                 3. Stage changed to a Won or Lost stage (any amount)
 *                      -> Opportunity_Alert_Closed_Deal_Emails
 *               Won stages are the Forecast Category Closed stages and Lost stages are the
 *               Forecast Category Omitted stages (STAGES_WON / STAGES_LOST).
 *               Rules apply only to deals owned by the department head
 *               (Opportunity_Alert_Department_Head_Username) or a user under the head: direct or
 *               indirect reports by Manager, or users in the head's role or any role below it.
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

    // Stage values that trigger closed-deal alerts
    //Added @dhanush on 03/11/2026 made public so AccountBusinessTypeHandler uses the same won stages
    public static final Set<String> STAGES_WON = new Set<String>{
        'Invoiced', 'Invoiced - Delivery Pending', 'Invoiced - Delivery in Progress', 'Overdue', 'Collected'
    };
    private static final Set<String> STAGES_LOST = new Set<String>{
        'Campaign', 'Closed Lost', 'Closed-Lost to Competition', 'Cold', 'Deferred', 'Solution Declined', 'Training Cancelled'
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

    // Department head and the users under the head (cached per transaction; null if the head is not found)
    @TestVisible
    private static Set<Id> departmentUserIds;
    @TestVisible
    private static Boolean departmentUserIdsLoaded = false;

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
     * @description Entry point from OpportunityTrigger (after update). Builds the alert
     *              emails for the updated deals, sends them in bulk and logs each sent
     *              email as an email activity on its deal.
     * @param newOpps   Trigger.new - updated Opportunity records
     * @param oldOppMap Trigger.oldMap - Opportunity records before the update
     */
    public static void handleAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap) {
        sendEmailsInBulk(buildAlertEmails(newOpps, oldOppMap));
        emailInvocationsSnapshot = Limits.getEmailInvocations();
        dmlStatementsSnapshot = Limits.getDmlStatements();
    }

    // ---------------- Rule evaluation ----------------

    /**
     * @description Evaluates the alert rules for each updated Opportunity and builds one
     *              email per matching deal. Does not send the emails.
     * @param newOpps   Updated Opportunity records
     * @param oldOppMap Opportunity records before the update
     * @return List of alert emails ready to be sent (empty if no rule matched)
     */
    @TestVisible
    private static List<AlertEmail> buildAlertEmails(
        List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap
    ) {
        List<AlertEmail> emails = new List<AlertEmail>();
        if (newOpps == null || newOpps.isEmpty() || oldOppMap == null) return emails;

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
            Opportunity oldOpp = oldOppMap.get(opp.Id);
            if (oldOpp == null || processedOppIds.contains(opp.Id)) continue;

            Decimal amount = opp.Amount == null ? 0 : opp.Amount;
            Decimal oldAmount = oldOpp.Amount == null ? 0 : oldOpp.Amount;
            // High value before or after the change, so a drop below 25 Lakhs still alerts
            Boolean isHighValue = amount >= HIGH_VALUE_THRESHOLD || oldAmount >= HIGH_VALUE_THRESHOLD;
            Boolean stageChanged = opp.StageName != oldOpp.StageName;
            Boolean amountChanged = opp.Amount != oldOpp.Amount;
            Boolean movedToWon = stageChanged && STAGES_WON.contains(opp.StageName);
            Boolean movedToLost = stageChanged && STAGES_LOST.contains(opp.StageName);

            Set<String> recipients = new Set<String>();
            List<String> reasons = new List<String>();

            // Rule 1: High value deal with Stage or Amount change
            if (isHighValue && (stageChanged || amountChanged)) {
                recipients.addAll(highValueEmails);
                reasons.add('High value deal (25 Lakhs or above) - ' +
                    (stageChanged && amountChanged ? 'Stage and Amount changed'
                        : stageChanged ? 'Stage changed' : 'Amount changed'));
            }
            // Rule 2: Deal of 10 Lakhs or above moved to a Won / Lost stage
            if ((movedToWon || movedToLost) && amount >= CLOSED_DEAL_THRESHOLD) {
                recipients.addAll(closedWon10LEmails);
                reasons.add('Deal of 10 Lakhs or above moved to ' + opp.StageName);
            }
            // Rule 3: Any deal moved to a Won / Lost stage
            if (movedToWon || movedToLost) {
                recipients.addAll(closedDealEmails);
                reasons.add('Deal moved to ' + opp.StageName);
            }

            if (recipients.isEmpty() || !isDepartmentDeal(opp)) continue;
            processedOppIds.add(opp.Id);

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>(recipients));
            email.setSubject(buildSubject(opp, movedToWon, movedToLost));
            email.setHtmlBody(buildHtmlBody(opp, oldOpp, reasons, orgUrl));
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

    // ---------------- Department filter ----------------

    /**
     * @description Checks whether a deal is owned by the department head or a user under the
     *              head. Users are queried once per transaction and cached, and only when a
     *              deal matches an alert rule. If the head is not found the deal is treated as
     *              in scope, so a wrong label cannot silently stop every alert.
     * @param opp Updated Opportunity
     * @return True if the deal should alert
     */
    private static Boolean isDepartmentDeal(Opportunity opp) {
        if (!departmentUserIdsLoaded) {
            departmentUserIdsLoaded = true;
            String headUsername = System.Label.Opportunity_Alert_Department_Head_Username.trim();
            departmentUserIds = findDepartmentUsers(
                headUsername,
                [SELECT Id, Username, ManagerId, UserRoleId FROM User WHERE UserType = 'Standard'],
                [SELECT Id, ParentRoleId FROM UserRole]
            );
            if (departmentUserIds == null) {
                System.debug(LoggingLevel.ERROR, 'Opportunity alert department filter skipped - head not found: ' + headUsername);
            }
        }
        return departmentUserIds == null || departmentUserIds.contains(opp.OwnerId);
    }

    /**
     * @description Finds the department head and the users under the head: direct or indirect
     *              reports by Manager, plus users in the head's role or any role below it.
     * @param headUsername Username of the department head
     * @param users        Users to search
     * @param roles        Roles to search
     * @return Ids of the head and the users under the head, or null if the head is not found
     */
    @TestVisible
    private static Set<Id> findDepartmentUsers(String headUsername, List<User> users, List<UserRole> roles) {
        User head;
        Map<Id, Id> managerByUser = new Map<Id, Id>();
        for (User u : users) {
            if (u.Username == headUsername) head = u;
            managerByUser.put(u.Id, u.ManagerId);
        }
        if (head == null) return null;

        Set<Id> departmentUsers = rollUpTo(head.Id, managerByUser);
        if (head.UserRoleId != null) {
            Map<Id, Id> parentByRole = new Map<Id, Id>();
            for (UserRole role : roles) {
                parentByRole.put(role.Id, role.ParentRoleId);
            }
            Set<Id> departmentRoles = rollUpTo(head.UserRoleId, parentByRole);
            for (User u : users) {
                if (departmentRoles.contains(u.UserRoleId)) departmentUsers.add(u.Id);
            }
        }
        return departmentUsers;
    }

    /**
     * @description Returns the root plus every record that rolls up to it, direct or indirect.
     * @param rootId     Top of the hierarchy
     * @param parentById Each record's Id mapped to its parent's Id
     * @return Ids of the root and the records under it
     */
    private static Set<Id> rollUpTo(Id rootId, Map<Id, Id> parentById) {
        Set<Id> members = new Set<Id>{ rootId };
        Integer previousSize = 0;
        // Each pass adds one more level; stops when a pass adds nobody
        while (members.size() != previousSize) {
            previousSize = members.size();
            for (Id childId : parentById.keySet()) {
                if (members.contains(parentById.get(childId))) members.add(childId);
            }
        }
        return members;
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
     * @param opp         Updated Opportunity
     * @param movedToWon  True if the stage just changed to a Won stage
     * @param movedToLost True if the stage just changed to a Lost stage
     * @return Email subject
     */
    private static String buildSubject(Opportunity opp, Boolean movedToWon, Boolean movedToLost) {
        String prefix = movedToWon ? 'Deal Won' : movedToLost ? 'Deal Lost' : 'High Value Deal Update';
        return prefix + ': ' + opp.Name + ' (' + formatLakhs(opp.Amount) + ')';
    }

    /**
     * @description Builds the HTML email body with the alert reasons and deal details.
     * @param opp     Updated Opportunity
     * @param oldOpp  Opportunity before the update (used to show old -> new values)
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
            '<p>The following deal has been updated and requires your attention:</p>' +
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