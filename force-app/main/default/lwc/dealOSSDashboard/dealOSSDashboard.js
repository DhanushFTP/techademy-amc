/******************************************************************
 * Component Name : dealOSSDashboard
 * Company        : Fingertip Technologies Pvt Ltd
 * Created Date   : 22-05-2026
 * @description   : Lightning Web Component for the Opportunity record
 *                  page. Shows the Opportunity Score, the Deal Strategy
 *                  Summary, and (on toggle) the full OSS coaching table.
 *                  Refreshes automatically when the Opportunity is saved.
 * @author        : Naveen Kumar R
 * Used By        : - Opportunity Lightning Record Page
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Naveen Kumar R  | 22-05-2026 | Initial version
 * -----------------------------------------------------------------------------
 ******************************************************************/
import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import getDashboard from '@salesforce/apex/DealOSSCalculationController.getDashboard';
import LAST_MODIFIED from '@salesforce/schema/Opportunity.LastModifiedDate';

export default class DealOSSDashboard extends LightningElement {
    @api recordId;
    rows;
    strategyRows;
    opportunityScore;
    isOutdated = false;
    outdatedRemark = '';
    error;
    loading = true;
    showTable = false;
    showDashboard = false;

    _wiredDashboard;
    _lastModified;
    _iframeNonce = Date.now();

    @wire(getDashboard, { recordId: '$recordId' })
    wiredDashboard(result) {
        this._wiredDashboard = result;
        const { data, error } = result;
        this.loading = false;
        if (data) {
            this.opportunityScore = data.opportunityScore;
            this.isOutdated = data.isOutdated === true;
            this.outdatedRemark = data.outdatedRemark || '';
            this.strategyRows = this.buildStrategyRows(data.strategy);
            this.rows = (data.rows || []).map((r) => {
                const sClass = this.scoreClass(r.score);
                return {
                    ...r,
                    hasScore: r.score !== null && r.score !== undefined,
                    rowClass: `data-row ${sClass}`,
                    scoreBadge: `score-badge ${sClass}`,
                    actionPlanLines: (r.actionPlan || '')
                        .split('\n')
                        .filter((t) => t && t.trim())
                        .map((t, i) => ({ id: i, text: t }))
                };
            });
            this.error = undefined;
        } else if (error) {
            this.error =
                (error && error.body && error.body.message) ||
                'Unable to load the OSS dashboard.';
            this.rows = undefined;
        }
    }

    // Refreshes the dashboard whenever the Opportunity record is saved.
    @wire(getRecord, { recordId: '$recordId', fields: [LAST_MODIFIED] })
    wiredRecord({ data }) {
        if (data) {
            const lm = getFieldValue(data, LAST_MODIFIED);
            if (this._lastModified && this._lastModified !== lm) {
                this.loading = true;
                refreshApex(this._wiredDashboard);
                this._iframeNonce = Date.now();
            }
            this._lastModified = lm;
        }
    }

    buildStrategyRows(s) {
        if (!s) {
            return [];
        }
        return [
            { key: 'cur', label: 'You are currently', value: s.youAreCurrently, valueClass: 'strat-value' },
            { key: 'mis', label: 'Missing', value: s.missing, valueClass: 'strat-value' },
            { key: 'shift', label: 'Strategy shift', value: s.strategyShift, valueClass: 'strat-value' },
            { key: 'next', label: 'Next best action', value: s.nextBestAction, valueClass: 'strat-value' },
            { key: 'top', label: 'Top performer benchmark', value: s.topPerformerBenchmark, valueClass: 'strat-value' },
            {
                key: 'stop',
                label: 'Hard-stop alert',
                value: s.hardStopAlert,
                valueClass: `strat-value ${this.alertClass(s.hardStopAlert)}`
            }
        ];
    }

    alertClass(text) {
        if (!text) {
            return '';
        }
        if (text.indexOf('STOP') === 0) {
            return 'alert-stop';
        }
        if (text.indexOf('CAUTION') === 0) {
            return 'alert-caution';
        }
        return 'alert-ok';
    }

    handleToggle(event) {
        this.showTable = event.target.checked;
    }

    handleDashboardToggle(event) {
        this.showDashboard = event.target.checked;
    }

    get trendUrl() {
        return this.recordId
            ? `/apex/OSSScoreTrendChart?id=${this.recordId}&_=${this._iframeNonce}`
            : '';
    }

    scoreClass(score) {
        if (score === 2) return 's-2';
        if (score === 1) return 's-1';
        if (score === 0) return 's-0';
        if (score === -1) return 's-neg';
        return 's-na';
    }

    get opportunityScoreDisplay() {
        return this.opportunityScore !== null && this.opportunityScore !== undefined
            ? Number(this.opportunityScore).toFixed(2)
            : '—';
    }

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }

    get hasStrategy() {
        return this.strategyRows && this.strategyRows.length > 0;
    }

    get scorecardClass() {
        return this.isOutdated ? 'scorecard outdated' : 'scorecard';
    }

    get scoreValueClass() {
        return this.isOutdated ? 'sc-value outdated' : 'sc-value';
    }

    get showOutdatedRemark() {
        return this.isOutdated && Boolean(this.outdatedRemark);
    }
}