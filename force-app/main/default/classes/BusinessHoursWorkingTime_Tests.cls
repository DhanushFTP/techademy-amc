@IsTest(SeeAllData=true) // uses the org's Business Hours
private class BusinessHoursWorkingTime_Tests {
    @IsTest
    static void test_calc() {
        // Get default BH; test assumes one exists as you configured earlier
        List<BusinessHours> bhs = [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1];
        System.assert(!bhs.isEmpty(), 'Default Business Hours must exist for this test.');
        Id bhId = bhs[0].Id;

        Datetime startDT = Datetime.newInstance(2025, 1, 2, 8, 0, 0);
        Long twelveHoursMs = 12L * 60 * 60 * 1000;
        Datetime endDT = BusinessHours.add(bhId, startDT, twelveHoursMs);

        BusinessHoursWorkingTime.Input good = new BusinessHoursWorkingTime.Input();
        good.startDT = startDT; good.endDT = endDT; good.businessHoursId = bhId;

        BusinessHoursWorkingTime.Input bad = new BusinessHoursWorkingTime.Input();
        bad.startDT = endDT; bad.endDT = startDT; bad.businessHoursId = bhId;

        List<BusinessHoursWorkingTime.Output> outs =
            BusinessHoursWorkingTime.calc(new List<BusinessHoursWorkingTime.Input>{ good, bad });

        System.assertEquals(2, outs.size());
        System.assertEquals(twelveHoursMs, outs[0].milliseconds, 'should be 12h in ms');
        System.assertEquals(12, outs[0].hours, 'should be 12.00 hours');
        System.assertEquals(0, outs[1].milliseconds);
        System.assertEquals(0, outs[1].hours);
    }
}