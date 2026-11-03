public with sharing class BusinessHoursWorkingTime {
    public class Input {
        @InvocableVariable public Datetime startDT;
        @InvocableVariable public Datetime endDT;
        @InvocableVariable public Id businessHoursId; // may come in as '' via Flow
    }
    public class Output {
        @InvocableVariable public Decimal hours;
        @InvocableVariable public Long milliseconds;
    }

    @InvocableMethod(
        label='Calculate Working Hours (BusinessHours.diff)'
        description='Returns working time between two DateTimes using a Business Hours record'
    )
    public static List<Output> calc(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        if (inputs == null || inputs.isEmpty()) return outs;

        // Default BH (optional)
        Id defaultBhId = null;
        List<BusinessHours> bh = [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1];
        if (!bh.isEmpty()) defaultBhId = bh[0].Id;

        for (Input i : inputs) {
            Output o = new Output();
            // Guard: nulls or reversed dates -> zero
            if (i == null || i.startDT == null || i.endDT == null || i.endDT < i.startDT) {
                o.milliseconds = 0L; o.hours = 0; outs.add(o); continue;
            }

            // Sanitize BH Id: treat blank/whitespace or malformed as null
            Id bhId = null;
            if (i.businessHoursId != null) {
                String raw = String.valueOf(i.businessHoursId).trim();
                if (raw != null && raw.length() == 18) {
                    // Safe cast
                    try { bhId = (Id)raw; } catch (Exception e) { bhId = null; }
                }
            }
            if (bhId == null) bhId = defaultBhId;

            Long ms = 0L;
            try {
                ms = (bhId == null) ? 0L : BusinessHours.diff(bhId, i.startDT, i.endDT);
                if (ms == null) ms = 0L;
            } catch (Exception e) {
                // If anything goes wrong, return zero rather than failing the save
                ms = 0L;
            }

            o.milliseconds = ms;
            o.hours = (Decimal.valueOf(ms) / (1000 * 60 * 60)).setScale(2, RoundingMode.HALF_UP);
            outs.add(o);
        }
        return outs;
    }
}