import { LightningElement, track, api, wire } from 'lwc';
import { CloseActionScreenEvent }             from 'lightning/actions';
import { getRecord }                          from 'lightning/uiRecordApi';
import saveConfig             from '@salesforce/apex/McubeConfigController.saveConfig';
import checkExistingConfig    from '@salesforce/apex/McubeConfigController.checkExistingConfig';
import getAllObjects          from '@salesforce/apex/McubeConfigController.getAllObjects';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjectFields from '@salesforce/apex/McubeConfigController.getObjectFields';
import getMcubeFields from '@salesforce/apex/McubeConfigController.getMcubeFields';
import getCallActivityMapping from '@salesforce/apex/McubeConfigController.getCallActivityMapping';
import getLandingNumbers from '@salesforce/apex/McubeConfigController.getLandingNumbers';

const SOURCES = ['Newspaper','Hoarding','Digital','TV','Radio','Event','Referral','Cold Call'];

export default class McubeConfigWizard extends LightningElement {
    @track objectFields = [];
    @track allObjects = [];

    // ── Wire: Fetch all available Salesforce objects ──
    @wire(getAllObjects)
    wiredAllObjects({ data, error }) {
        if (data) {
            this.allObjects = data;
            console.log('[MCube] getAllObjects loaded, count:', data.length);
        }
        if (error) console.error('[MCube] getAllObjects failed:', error);
    }

    // ── Wire: Fetch fields for selected object ──
    @wire(getObjectFields, { objectName: '$curObj' })
    wiredObjectFields({ data, error }) {
        if (data) this.objectFields = data;
        if (error) console.error('[MCube] getObjectFields failed:', error);
    }

    // requiredFields becomes a getter:
    get requiredFields() {
        const reqs = this.objectFields.filter(f => f.isRequired).map(f => f.apiName);
        return reqs.length ? reqs.join(', ') : 'none';
    }

    @track mcubeFields = [];

    @wire(getMcubeFields)
    wiredMcubeFields({ data }) {
        if (data) this.mcubeFields = data;
    }

    // ── Call Activity section — its own object + fields (independent of curObj) ──
    @track callActivityEnabled = false;   // toggle, default OFF
    @track callActivityObj = '';
    @track callActivityFields = [];

    @wire(getObjectFields, { objectName: '$callActivityObj' })
    wiredCallActivityFields({ data, error }) {
        if (data) this.callActivityFields = data;
        if (error) console.error('[MCube] callActivity getObjectFields failed:', error);
    }

    @track callActivityRows = [
        { id: 1, lhsField: '', rhsType: 'mcube', rhsVal: '' }
    ];
    _callActivityCounter = 2;

    // ── Edit mode: load Call Activity mapping on its OWN wire ──
    // Kept separate from getRecord so a missing/empty mapping never
    // blocks the source-object load or any existing step.
    @wire(getCallActivityMapping, { recordId: '$recordId' })
    wiredCallActivityMapping({ data }) {
        if (!data) return;
        try {
            const p = JSON.parse(data);
            this.callActivityEnabled = p.enabled || false;
            this.callActivityObj     = p.object || '';
            if ((p.mappings || []).length) {
                const mcube = this.mcubeFields || [];
                this.callActivityRows = p.mappings.map((m, i) => ({
                    id: i + 1,
                    lhsField: m.field,
                    // type isn't stored — infer from whether the value is an MCube field
                    rhsType: m.type || (mcube.includes(m.value) ? 'mcube' : 'static'),
                    rhsVal: m.value
                }));
                this._callActivityCounter = p.mappings.length + 1;
            }
        } catch(e) { console.error('Call activity mapping parse error', e); }
    }

    @track currentStep = 1;
    @track curObj = '';
    @track isActive = false;
    @track isSaving = false;
    @track configMode = 'BOTH';   // 'BOTH' | 'OUTBOUND_ONLY'
    @track priority = '';         // routing tiebreak (BOTH mode only); digits only, optional
    @api recordId;   // null = New,  populated = Edit

    // Duplicate-config detection (Step 1)
    @track existingConfigWarning = '';
    @track existingConfigId = null;

    // Used in HTML template
    @track dedupError = '';

    @wire(getRecord, {
        recordId: '$recordId',
        fields: [
            'MCube_Configuration__c.Name',
            'MCube_Configuration__c.Source_Object__c',
            'MCube_Configuration__c.Duplication_rule__c',
            'MCube_Configuration__c.Default_Values__c',
            'MCube_Configuration__c.Landing_Number__c',
            'MCube_Configuration__c.Outbound_Fields__c',
            'MCube_Configuration__c.Is_Active__c',
            'MCube_Configuration__c.Is_Default__c',
            'MCube_Configuration__c.Create_If_Not_Found__c',
            'MCube_Configuration__c.Configuration_Mode__c',
            'MCube_Configuration__c.Priority__c'
        ]
    })
    wiredRecord({ data, error }) {
        if (!data || !this.recordId) return;

        const f = data.fields;

        // ── Step 1 ───────────────────────────────────────────────────
        this.curObj         = f.Source_Object__c.value || '';
        this.isActive       = f.Is_Active__c.value || false;
        this.configMode     = f.Configuration_Mode__c?.value || 'BOTH';
        this.priority       = f.Priority__c?.value || '';

        // In edit mode we don't need to warn about duplicates
        this.existingConfigWarning = '';
        this.existingConfigId = null;

        // ── Step 2 — rebuild dedupRows from SOQL string ──────────────
        const soql = f.Duplication_rule__c.value || '';
        if (soql) this.dedupRows = this._parseDedupSOQL(soql);

        // ── Step 3 — rebuild defaultRows ────────────────────────────
        const defRaw = f.Default_Values__c.value;
        if (defRaw) {
            try {
                const parsed = JSON.parse(defRaw);
                this.defaultRows    = parsed.map((r, i) => ({ id: i + 1, field: r.field, value: r.value }));
                this._defaultCounter = parsed.length + 1;
            } catch(e) { console.error('Default values parse error', e); }
        }

        // ── Step 4 — rebuild landingSources from JSON map ────────────
        const lnRaw = f.Landing_Number__c.value;
        if (lnRaw && !this._landingLoadedFromChild) {
            try {
                const lnMap = JSON.parse(lnRaw);
                let lsId = 1;
                this.landingSources = Object.entries(lnMap).map(([source, val]) => ({
                    id     : lsId++,
                    source,
                    number : Array.isArray(val) ? (val[0] || '') : (val || ''),
                    campaign: '',
                    warn   : ''
                }));
                this._lsCounter = lsId;
            } catch(e) { console.error('Landing number parse error', e); }
        }

        // ── Step 5 — rebuild outboundRows ───────────────────────────
        const obRaw = f.Outbound_Fields__c.value;
        if (obRaw) {
            try {
                const parsed = JSON.parse(obRaw);
                this.outboundRows   = parsed.map(r => ({ id: r.order, field: r.field, label: r.label }));
                this._obCounter     = parsed.length + 1;
            } catch(e) { console.error('Outbound fields parse error', e); }
        }
    }

    _parseDedupSOQL(soql) {
        const whereMatch = soql.match(/WHERE\s+(.+)$/i);
        if (!whereMatch) return this.dedupRows;

        const whereStr = whereMatch[1].trim();

        // Extract each `field = value` condition in order of appearance.
        const condRegex  = /[\w.]+\s*=\s*(?::\w+|'[^']*'|[\w.]+)/g;
        const conditions = whereStr.match(condRegex) || [];
        if (!conditions.length) return this.dedupRows;

        const rows = [];
        let counter = 1;
        conditions.forEach(condition => {
            const eq  = condition.indexOf('=');
            const lhs = condition.slice(0, eq).trim();
            const rhs = condition.slice(eq + 1).trim();

            let rhsType, rhsVal;
            if      (rhs.startsWith(':lookupId_')) { rhsType = 'lookup'; rhsVal = ''; }
            else if (rhs.startsWith(':'))          { rhsType = 'mcube';  rhsVal = rhs.slice(1); }
            else if (rhs.startsWith("'") && rhs.endsWith("'")) {
                const literal = rhs.replace(/^'|'$/g, '');
                if (/^[a-zA-Z0-9]{15,18}$/.test(literal)) { rhsType = 'lookup'; rhsVal = literal; }
                else                                       { rhsType = 'static'; rhsVal = literal; }
            } else { rhsType = 'static'; rhsVal = rhs; }

            rows.push({ id: counter++, lhsField: lhs, rhsType, rhsVal });
        });
        this._dedupCounter = counter;

        // Normalized logic: replace each condition (in order) with its 1-based number.
        let logicStr = whereStr;
        conditions.forEach((c, idx) => { logicStr = logicStr.replace(c, String(idx + 1)); });
        logicStr = logicStr.replace(/\s+/g, ' ').trim();

        // Derive the matching mode from the normalized logic.
        const hasParens = /[()]/.test(logicStr);
        const hasAnd    = /\bAND\b/i.test(logicStr);
        const hasOr     = /\bOR\b/i.test(logicStr);
        if (hasParens || (hasAnd && hasOr)) {
            this.dedupLogicType   = 'custom';
            this.dedupCustomLogic = logicStr;
        } else if (hasOr) {
            this.dedupLogicType = 'any';
        } else {
            this.dedupLogicType = 'all';
        }

        return rows;
    }

    /**
     * Dynamically build object options from wired allObjects data
     * Includes placeholder option at the top
     */
    get objectOptions() {
        return [
            { label: '— select object —', value: '', selected: !this.curObj },
            ...this.allObjects.map(obj => ({
                label: obj.label,
                value: obj.apiName,
                selected: obj.apiName === this.curObj
            }))
        ];
    }

    // Step 2 – dedup rows
    @track dedupRows = [
        { id: 1, lhsField: '', rhsType: 'mcube', rhsVal: 'customerNumber' }
    ];
    _dedupCounter = 2;

    // Step 2 – matching logic: 'all' (AND) | 'any' (OR) | 'custom'
    @track dedupLogicType   = 'all';
    @track dedupCustomLogic = '';   // e.g. "1 AND (2 OR 3)"

    // Step 3 – default rows
    @track defaultRows = [
        { id: 1, field: 'LastName',   value: '' },
        { id: 2, field: 'Company',    value: 'Unknown' },
        { id: 3, field: 'LeadSource', value: 'MCube Call' }
    ];
    _defaultCounter = 4;

    // Step 4 – landing sources  (one source = one landing number)
    @track landingSources = [
        { id: 1, source: 'Newspaper', number: '001', campaign: '', warn: '' },
        { id: 2, source: 'Hoarding',  number: '002', campaign: '', warn: '' }
    ];
    _lsCounter = 3;
    _landingLoadedFromChild = false;

    // ── Edit mode: load landing rows (incl. campaign) from the child object ──
    // Takes precedence over the legacy Landing_Number__c JSON map.
    @wire(getLandingNumbers, { recordId: '$recordId' })
    wiredLandingNumbers({ data }) {
        if (!data || !data.length) return;
        this._landingLoadedFromChild = true;
        let lsId = 1;
        this.landingSources = data.map(d => ({
            id: lsId++, source: d.source, number: d.num, campaign: d.campaign || '', warn: ''
        }));
        this._lsCounter = lsId;
    }

    // Step 5 – outbound rows
    @track outboundRows = [
        { id: 1, field: 'Mobile', label: 'Mobile' },
        { id: 2, field: 'Phone',  label: 'Phone'  }
    ];
    _obCounter = 3;

    /* ─── Step getters ─── */
    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }
    get isStep5() { return this.currentStep === 5; }
    get isStep6() { return this.currentStep === 6; }   // Call Activity
    get isStep7() { return this.currentStep === 7; }   // Activate
    get isNewMode()  { return !this.recordId; }
    get isEditMode() { return !!this.recordId; }
    get isPlaceholderSelected() { return !this.curObj; }
    get hasExistingConfig() { return !!this.existingConfigWarning; }

    /* ─── Mode getters ─── */
    get isBothMode()     { return this.configMode === 'BOTH'; }
    get isOutboundOnly() { return this.configMode === 'OUTBOUND_ONLY'; }

    get stepPills() {
        const map = this.isOutboundOnly
            ? [
                { label: '1 · Source',        step: 1 },
                { label: '2 · Outbound',              step: 5 },
                { label: '3 · Capture Call Activity', step: 6 },
                { label: '4 · Activate',              step: 7 }
              ]
            : [
                { label: '1 · Source',        step: 1 },
                { label: '2 · Dedup Check',   step: 2 },
                { label: '3 · Defaults',      step: 3 },
                { label: '4 · Landing #',     step: 4 },
                { label: '5 · Outbound',              step: 5 },
                { label: '6 · Capture Call Activity', step: 6 },
                { label: '7 · Activate',              step: 7 }
              ];
        return map.map(({ label, step }) => {
            let cls = 'step-pill';
            if (step === this.currentStep) cls += ' active';
            else if (step < this.currentStep) cls += ' done';
            return { label, n: step, cls };
        });
    }

    get fieldOptions() {
        return [
            { label: '— field —', value: '' },
            ...this.objectFields.map(f => ({
                label: f.label + (f.isLookup ? ' 🔗' : ''),
                value: f.apiName
            }))
        ];
    }
    get mcubeFieldOptions() {
        return [
            { label: '— MCube field —', value: '' },
            ...this.mcubeFields.map(f => ({ label: f, value: f }))
        ];
    }
    get sourceOptions() {
        return [...SOURCES, 'Custom'].map(s => ({ label: s, value: s }));
    }

    /* ─── Call Activity (Step 6) getters ─── */
    get callActivityObjectOptions() {
        return [
            { label: '— select object —', value: '', selected: !this.callActivityObj },
            ...this.allObjects.map(obj => ({
                label: obj.label,
                value: obj.apiName,
                selected: obj.apiName === this.callActivityObj
            }))
        ];
    }
    get callActivityFieldOptions() {
        return [
            { label: '— field —', value: '' },
            ...this.callActivityFields.map(f => ({
                label: f.label,
                value: f.apiName
            }))
        ];
    }
    get callActivityRowsView() {
        return this.callActivityRows.map(row => ({
            ...row,
            fieldOptions:   this.callActivityFieldOptions.map(o => ({ ...o, selected: o.value === row.lhsField })),
            isMcube:        row.rhsType === 'mcube',
            isStatic:       row.rhsType === 'static',
            tabMcubeClass:  'rhs-tab' + (row.rhsType === 'mcube'  ? ' active' : ''),
            tabStaticClass: 'rhs-tab' + (row.rhsType === 'static' ? ' active' : ''),
            mcubeOptions:   this.mcubeFieldOptions.map(o => ({ ...o, selected: o.value === row.rhsVal }))
        }));
    }
    get callActivityToggleTrackClass() { return 'toggle-track' + (this.callActivityEnabled ? ' on' : ''); }
    get callActivityToggleLabel()      { return this.callActivityEnabled ? 'Enabled' : 'Disabled'; }
    get callActivityToggleLabelClass() { return 'toggle-label' + (this.callActivityEnabled ? ' on' : ''); }

    // Dedup rows enriched for template
    get dedupRowsView() {
        return this.dedupRows.map((row, i) => {
            const fieldMeta = this.objectFields.find(f => f.apiName === row.lhsField);
            return {
                ...row,
                num:            i + 1,
                fieldOptions:   this.fieldOptions.map(o => ({ ...o, selected: o.value === row.lhsField })),
                isLookup:       fieldMeta?.isLookup || false,
                lookupObjApi:   fieldMeta?.referenceTo || '',
                isLookupType: row.rhsType === 'lookup',
                isMcube:        row.rhsType === 'mcube',
                isStatic:       row.rhsType === 'static',
                tabMcubeClass:  'rhs-tab' + (row.rhsType === 'mcube'  ? ' active' : ''),
                tabStaticClass: 'rhs-tab' + (row.rhsType === 'static' ? ' active' : ''),
                tabLookupClass: 'rhs-tab' + (row.rhsType === 'lookup' ? ' active' : ''),
                mcubeOptions:   this.mcubeFieldOptions.map(o => ({ ...o, selected: o.value === row.rhsVal }))
            };
        });
    }

    /* ─── Dedup matching-logic selector getters ─── */
    get dedupLogicCustom()      { return this.dedupLogicType === 'custom'; }

    // Human-readable dedup rule for the Activate summary — shows the same
    // AND / OR / custom logic the user built in the Dedup Check step.
    get dedupSummary() {
        const condByPos = this.dedupRows.map(r => r.lhsField ? `${r.lhsField} = ${r.rhsVal || r.rhsType}` : null);
        const valid = condByPos.filter(Boolean);
        if (!valid.length) return 'none';
        if (this.dedupLogicType === 'any') return valid.join(' OR ');
        if (this.dedupLogicType === 'custom') {
            return (this.dedupCustomLogic || '').replace(/\d+/g, m => {
                const c = condByPos[parseInt(m, 10) - 1];
                return c ? c : m;
            }) || 'none';
        }
        return valid.join(' AND ');
    }
    get dedupLogicAllClass()    { return 'rhs-tab' + (this.dedupLogicType === 'all'    ? ' active' : ''); }
    get dedupLogicAnyClass()    { return 'rhs-tab' + (this.dedupLogicType === 'any'    ? ' active' : ''); }
    get dedupLogicCustomClass() { return 'rhs-tab' + (this.dedupLogicType === 'custom' ? ' active' : ''); }

    // Default rows enriched
    get defaultRowsView() {
        const reqs = this.objectFields.filter(f => f.isRequired).map(f => f.apiName);
        return this.defaultRows.map(row => ({
            ...row,
            fieldOptions: this.fieldOptions.map(o => ({ ...o, selected: o.value === row.field })),
            isRequired:   row.field && reqs.includes(row.field)
        }));
    }

    // Landing sources enriched
    get landingSourcesView() {
        return this.landingSources.map(src => ({
            ...src,
            sourceOptions: this.sourceOptions.map(o => ({ ...o, selected: o.value === src.source }))
        }));
    }

    // Outbound rows enriched
    get outboundRowsView() {
        return this.outboundRows.map((row, i) => ({
            ...row,
            order:        i + 1,
            fieldOptions: this.fieldOptions.map(o => ({ ...o, selected: o.value === row.field }))
        }));
    }

    // Step 6 summary
    get cfgTitle() { return `MCube — ${this.curObj} config`; }
    get cfgSub() {
        if (this.isOutboundOnly) {
            return `Outbound only · ${this.outboundRows.filter(r => r.field).length} phone fields`;
        }
        const dd = this.dedupRows.filter(r => r.lhsField).length;
        const ls = this.landingSources.length;
        return `Inbound + outbound · ${dd} dedup rules · ${ls} sources`;
    }
    get summaryRows() {
        if (this.isOutboundOnly) {
            return [
                { key: 'Source object',   val: this.curObj },
                { key: 'Mode',            val: 'Outbound only' },
                { key: 'Outbound fields', val: this.outboundRows.filter(r => r.field).map((r, i) => `${i + 1}. ${r.field}`).join(', ') || 'none' },
                { key: 'Call activity',   val: this.callActivitySummary },
                { key: 'Status',          val: this.isActive ? 'Active' : 'Inactive' }
            ];
        }
        return [
            { key: 'Source object',   val: this.curObj },
            { key: 'Mode',            val: 'Inbound & Outbound' },
            { key: 'Priority',        val: this.priority || '—' },
            { key: 'Dedup rules',     val: this.dedupSummary },
            { key: 'Default values',  val: this.defaultRows.filter(r => r.field).map(r => `${r.field}="${r.value}"`).join(', ') || 'none' },
            { key: 'Landing sources', val: this.landingSources.filter(s => s.number).map(s => `${s.source} → ${s.number}`).join(', ') || 'none' },
            { key: 'Outbound fields', val: this.outboundRows.filter(r => r.field).map((r, i) => `${i + 1}. ${r.field}`).join(', ') || 'none' },
            { key: 'Call activity',   val: this.callActivitySummary },
            { key: 'Status',          val: this.isActive ? 'Active' : 'Inactive' }
        ];
    }
    get callActivitySummary() {
        if (!this.callActivityEnabled) return 'Disabled';
        const n = this.callActivityRows.filter(r => r.lhsField).length;
        return `${this.callActivityObj || '(no object)'} · ${n} field${n === 1 ? '' : 's'}`;
    }
    get toggleTrackClass()  { return 'toggle-track' + (this.isActive ? ' on' : ''); }
    get toggleLabel()       { return this.isActive ? 'Active' : 'Inactive'; }
    get toggleLabelClass()  { return 'toggle-label' + (this.isActive ? ' on' : ''); }

    /* ─── Mode change handler ─── */
    modeChange(event) {
        this.configMode = event.target.value;
        console.log('[MCube][Step1] Mode changed →', this.configMode);
    }
    // Priority accepts digits only (BOTH mode). Strip anything else and force the
    // input's value back so typed/pasted letters never remain visible (the tracked
    // value alone wouldn't re-render when only rejected chars were entered).
    priorityChange(event) {
        const clean = (event.target.value || '').replace(/[^0-9]/g, '');
        event.target.value = clean;
        this.priority = clean;
    }
    // Block non-digit keys before they even appear (typing path)
    priorityKeydown(event) {
        const allowed = ['Backspace','Delete','Tab','ArrowLeft','ArrowRight','Home','End'];
        if (allowed.includes(event.key) || event.ctrlKey || event.metaKey) return;
        if (!/^[0-9]$/.test(event.key)) event.preventDefault();
    }
    dedupLookupChange(event) {
        const id = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value || '';
        this.dedupRows = this.dedupRows.map(r => r.id !== id ? r : { ...r, rhsVal: val });
    }
    /* ─── Navigation ─── */
    nextStep() {
        if (this.currentStep === 1 && !this.curObj) {
            this.showToast('Validation Error', 'Please select a source object before continuing.', 'error');
            return;
        }
        if (this.currentStep === 1 && this.isNewMode && this.existingConfigId) {
            this.showToast(
                'Active configuration already exists',
                `An active configuration already exists for ${this.curObj}. Please edit the existing one or pick a different object.`,
                'warning'
            );
            return;
        }

        // ── Outbound-only flow: 1 → 5 → 6 → 7 ─────────────────────
        if (this.isOutboundOnly) {
            if (this.currentStep === 1)      this.currentStep = 5;
            else if (this.currentStep === 5) this.currentStep = 6;
            else if (this.currentStep === 6) this.currentStep = 7;
            console.log('[MCube] Step changed → currentStep:', this.currentStep, '(outbound-only)');
            return;
        }

        // ── Both mode validations ────────────────────────────────
        if (this.currentStep === 2 && !this._validateDedup()) return;

        if (this.currentStep === 3) {
            const reqs = this.objectFields.filter(f => f.isRequired).map(f => f.apiName);
            const missingReq = reqs.find(reqField => {
                const row = this.defaultRows.find(r => r.field === reqField);
                return !row || !row.value || row.value.trim() === '';
            });
            if (missingReq) {
                this.showToast('Validation Error', `Required field "${missingReq}" must have a default value.`, 'error');
                return;
            }
        }

        if (this.currentStep === 4) {
            if (!this.landingSources.length) {
                this.showToast('Validation Error', 'Please add at least one landing source.', 'error');
                return;
            }
            const emptyRow = this.landingSources.find(s => !(s.number || '').trim());
            if (emptyRow) {
                this.showToast('Validation Error', 'Every landing source must have a landing number.', 'error');
                return;
            }
        }

        if (this.currentStep < 7) this.currentStep++;
        console.log('[MCube] Step changed → currentStep:', this.currentStep);
    }

    previousStep() {
        // Outbound-only flow: 7 → 6 → 5 → 1
        if (this.isOutboundOnly) {
            if (this.currentStep === 5)      this.currentStep = 1;
            else if (this.currentStep === 6) this.currentStep = 5;
            else if (this.currentStep === 7) this.currentStep = 6;
            console.log('[MCube] Step changed ← currentStep:', this.currentStep, '(outbound-only)');
            return;
        }
        if (this.currentStep > 1) this.currentStep--;
        console.log('[MCube] Step changed ← currentStep:', this.currentStep);
    }

    /* ─── Step 1 ─── */
    objectSelection(event) {
        this.curObj         = event.target.value;
        console.log('[MCube][Step1] Object selected:', this.curObj, '| Required fields:', this.requiredFields);
        this._checkForExisting();
    }

    _checkForExisting() {
        if (!this.curObj || this.isEditMode) {
            this.existingConfigWarning = '';
            this.existingConfigId = null;
            return;
        }
        checkExistingConfig({ sourceObject: this.curObj })
            .then(result => {
                if (result) {
                    this.existingConfigId = result;
                    this.existingConfigWarning =
                        `An active configuration already exists for ${this.curObj}. ` +
                        `You can edit the existing one or pick a different object.`;
                } else {
                    this.existingConfigId = null;
                    this.existingConfigWarning = '';
                }
            })
            .catch(err => {
                console.error('[MCube][Step1] checkExistingConfig failed:', err);
                this.existingConfigWarning = '';
                this.existingConfigId = null;
            });
    }

    loadExistingConfig() {
        if (!this.existingConfigId) return;
        console.log('[MCube][Step1] Loading existing config:', this.existingConfigId);
        this.recordId = this.existingConfigId;
        this.existingConfigWarning = '';
    }

    /* ─── Step 2 – Dedup ─── */
    addDedupRow() {
        this.dedupRows = [
            ...this.dedupRows,
            { id: this._dedupCounter++, lhsField: '', rhsType: 'mcube', rhsVal: '' }
        ];
    }
    removeDedupRow(event) {
        const id = parseInt(event.currentTarget.dataset.id, 10);
        this.dedupRows = this.dedupRows.filter(r => r.id !== id);
    }
    _validateDedup() {
        const validCount = this.dedupRows.filter(r => r.lhsField).length;
        if (validCount === 0) {
            this.showToast('Validation Error', 'Please configure at least one dedup field.', 'error');
            return false;
        }

        if (this.dedupLogicType === 'custom') {
            const logic = (this.dedupCustomLogic || '').trim();
            if (!logic) {
                this.showToast('Validation Error', 'Please enter your custom matching logic (e.g. 1 AND (2 OR 3)).', 'error');
                return false;
            }
            // Only field numbers, AND, OR, parentheses and spaces are allowed
            const residue = logic.replace(/\bAND\b|\bOR\b/gi, ' ').replace(/[()]/g, ' ');
            if (/[^\d\s]/.test(residue)) {
                this.showToast('Validation Error', 'Custom logic may only contain field numbers, AND, OR, and parentheses.', 'error');
                return false;
            }
            // Balanced parentheses
            let depth = 0, balanced = true;
            for (const ch of logic) {
                if (ch === '(') depth++;
                else if (ch === ')') depth--;
                if (depth < 0) { balanced = false; break; }
            }
            if (!balanced || depth !== 0) {
                this.showToast('Validation Error', 'Custom logic has unbalanced parentheses.', 'error');
                return false;
            }
            // Every referenced number must point to a configured field row
            const nums = (logic.match(/\d+/g) || []).map(n => parseInt(n, 10));
            const badRef = nums.find(n => n < 1 || n > this.dedupRows.length || !this.dedupRows[n - 1].lhsField);
            if (badRef !== undefined) {
                this.showToast('Validation Error', `Custom logic references field ${badRef}, which is not a configured field.`, 'error');
                return false;
            }
            // Every configured field must be used at least once
            const missing = this.dedupRows
                .map((r, i) => (r.lhsField ? i + 1 : null))
                .filter(Boolean)
                .find(n => !nums.includes(n));
            if (missing !== undefined) {
                this.showToast('Validation Error', `Field ${missing} is configured but not used in your custom logic.`, 'error');
                return false;
            }
        }
        return true;
    }
    dedupLhsChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        const fieldMeta = this.objectFields.find(f => f.apiName === val);
        const isLookup = fieldMeta?.isLookup || false;
        this.dedupRows = this.dedupRows.map(r => {
            if (r.id !== id) return r;
            return { ...r, lhsField: val, rhsType: isLookup ? 'lookup' : r.rhsType, rhsVal: isLookup ? '' : r.rhsVal };
        });
    }
    setRhsType(event) {
        const id   = parseInt(event.currentTarget.dataset.id, 10);
        const type = event.currentTarget.dataset.type;
        this.dedupRows = this.dedupRows.map(r => r.id !== id ? r : { ...r, rhsType: type, rhsVal: '' });
    }
    dedupRhsValChange(event) {
        const id = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        this.dedupRows = this.dedupRows.map(r => r.id !== id ? r : { ...r, rhsVal: val });
    }
    setDedupLogic(event) {
        this.dedupLogicType = event.currentTarget.dataset.logic;   // 'all' | 'any' | 'custom'
    }
    dedupCustomLogicChange(event) {
        this.dedupCustomLogic = event.target.value;
    }

    /* ─── Step 3 – Defaults ─── */
    addDefaultRow() {
        this.defaultRows = [...this.defaultRows, { id: this._defaultCounter++, field: '', value: '' }];
    }
    removeDefaultRow(event) {
        const id   = parseInt(event.currentTarget.dataset.id, 10);
        const row  = this.defaultRows.find(r => r.id === id);
        const reqs = this.objectFields.filter(f => f.isRequired).map(f => f.apiName);
        if (row && reqs.includes(row.field)) {
            this.showToast('Cannot Remove', `"${row.field}" is a required field and cannot be removed.`, 'warning');
            return;
        }
        this.defaultRows = this.defaultRows.filter(r => r.id !== id);
    }
    defaultFieldChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        this.defaultRows = this.defaultRows.map(r => r.id !== id ? r : { ...r, field: val });
    }
    defaultValueChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        this.defaultRows = this.defaultRows.map(r => r.id !== id ? r : { ...r, value: val });
    }

    /* ─── Step 4 – Landing  (one source = one number) ─── */
    addLandingSource() {
        const used = this.landingSources.map(s => s.source);
        const next = SOURCES.find(s => !used.includes(s)) || 'Custom';
        this.landingSources = [
            ...this.landingSources,
            { id: this._lsCounter++, source: next, number: '', campaign: '', warn: '' }
        ];
    }
    removeLandingSource(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        this.landingSources = this.landingSources.filter(s => s.id !== id);
    }
    landingSourceChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        this.landingSources = this.landingSources.map(s =>
            s.id !== id ? s : { ...s, source: val }
        );
    }
    landingNumberChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        const conflict = this.landingSources.some(s =>
            s.id !== id && (s.number || '') === val && val !== ''
        );
        this.landingSources = this.landingSources.map(s =>
            s.id !== id ? s : { ...s, number: val, warn: conflict ? `"${val}" already used in another source` : '' }
        );
    }
    landingCampaignChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        this.landingSources = this.landingSources.map(s =>
            s.id !== id ? s : { ...s, campaign: val }
        );
    }

    /* ─── Step 5 – Outbound ─── */
    addOutboundRow() {
        const used = this.outboundRows.map(r => r.field);
        const next = this.objectFields.map(f => f.apiName).find(f => !used.includes(f)) || '';
        this.outboundRows = [...this.outboundRows, { id: this._obCounter++, field: next, label: next }];
    }
    removeOutboundRow(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        this.outboundRows = this.outboundRows.filter(r => r.id !== id);
    }
    outboundFieldChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        this.outboundRows = this.outboundRows.map(r =>
            r.id !== id ? r : { ...r, field: val, label: r.label || val }
        );
    }
    outboundLabelChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        this.outboundRows = this.outboundRows.map(r =>
            r.id !== id ? r : { ...r, label: val }
        );
    }

    /* ─── Step 6 – Call Activity ─── */
    toggleCallActivity() {
        this.callActivityEnabled = !this.callActivityEnabled;
    }
    callActivityObjChange(event) {
        this.callActivityObj = event.target.value;
        // Reset rows so stale field selections from a previous object are cleared
        this.callActivityRows = [{ id: 1, lhsField: '', rhsType: 'mcube', rhsVal: '' }];
        this._callActivityCounter = 2;
    }
    addCallActivityRow() {
        this.callActivityRows = [
            ...this.callActivityRows,
            { id: this._callActivityCounter++, lhsField: '', rhsType: 'mcube', rhsVal: '' }
        ];
    }
    removeCallActivityRow(event) {
        const id = parseInt(event.currentTarget.dataset.id, 10);
        this.callActivityRows = this.callActivityRows.filter(r => r.id !== id);
    }
    callActivityLhsChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        this.callActivityRows = this.callActivityRows.map(r => r.id !== id ? r : { ...r, lhsField: val });
    }
    setCallActivityRhsType(event) {
        const id   = parseInt(event.currentTarget.dataset.id, 10);
        const type = event.currentTarget.dataset.type;
        this.callActivityRows = this.callActivityRows.map(r => r.id !== id ? r : { ...r, rhsType: type, rhsVal: '' });
    }
    callActivityRhsValChange(event) {
        const id  = parseInt(event.currentTarget.dataset.id, 10);
        const val = event.target.value;
        this.callActivityRows = this.callActivityRows.map(r => r.id !== id ? r : { ...r, rhsVal: val });
    }

    /* ─── Step 7 – Activate & Save ─── */
    toggleActive() {
        this.isActive = !this.isActive;
    }

    _buildCallActivityMapping() {
        return JSON.stringify({
            enabled: this.callActivityEnabled,
            object:  this.callActivityEnabled ? this.callActivityObj : '',
            mappings: this.callActivityEnabled
                ? this.callActivityRows
                      .filter(r => r.lhsField)
                      .map(r => ({ field: r.lhsField, value: r.rhsVal }))
                : []
        });
    }

    saveConfiguration() {
        // ─────────────────────────────────────────────────────────────
        // OUTBOUND-ONLY: skip dedup/landing validation entirely
        // ─────────────────────────────────────────────────────────────
        if (this.isOutboundOnly) {
            const hasOutbound = this.outboundRows.some(r => r.field);
            if (!hasOutbound) {
                this.showToast('Validation Error', 'Please add at least one outbound phone field.', 'error');
                return;
            }

            this.isSaving = true;

            const outboundFields = JSON.stringify(
                this.outboundRows
                    .filter(r => r.field)
                    .map((r, i) => ({ order: i + 1, field: r.field, label: r.label }))
            );

            console.log('[MCube][Step6] ─── saveConfiguration (OUTBOUND_ONLY) ───');
            console.log('[MCube][Step6] sourceObject    :', this.curObj);
            console.log('[MCube][Step6] outboundFields  :', outboundFields);
            console.log('[MCube][Step6] isActive        :', this.isActive);
            console.log('[MCube][Step6] mode            :', this.isEditMode ? 'EDIT' : 'NEW');
            console.log('[MCube][Step6] ──────────────────────────────────────');

            const wasEdit = this.isEditMode;

            Promise.resolve(
                saveConfig({
                    configName      : `MCube - ${this.curObj}`,
                    sourceObject    : this.curObj,
                    duplicationRule : '',
                    defaultValues   : '[]',
                    landingNumbers  : '{}',
                    landingDetails  : '[]',
                    outboundFields  : outboundFields,
                    callActivityMapping: this._buildCallActivityMapping(),
                    createIfNotFound: false,
                    isActive        : this.isActive,
                    isDefault       : false,
                    recordId        : this.recordId || null,
                    configMode      : 'OUTBOUND_ONLY',
                    priority        : ''
                })
            )
            .then(() => {
                this.isSaving = false;
                const action = wasEdit ? 'updated' : 'created';
                console.log(`[MCube][Step6] ✅ Outbound-only config ${action} for:`, this.curObj);
                this.showToast(
                    wasEdit ? 'Configuration Updated' : 'Configuration Created',
                    `Outbound-only configuration ${action} for ${this.curObj}.`,
                    'success'
                );
                this.dispatchEvent(new CustomEvent('closemodal'));
            })
            .catch(err => {
                this.isSaving = false;
                console.error('[MCube][Step6] ❌ Save failed:', JSON.stringify(err));
                this.showToast('Save Failed', err?.body?.message || 'An unexpected error occurred.', 'error');
            });

            return;
        }

        // ─────────────────────────────────────────────────────────────
        // BOTH (Inbound + Outbound) — original full save flow
        // ─────────────────────────────────────────────────────────────
        const hasDedupField = this.dedupRows.some(r => r.lhsField);
        if (!hasDedupField) {
            this.showToast('Validation Error', 'Please set at least one dedup field in Step 2.', 'error');
            return;
        }

        if (!this.landingSources.length ||
            this.landingSources.some(s => !(s.number || '').trim())) {
            this.showToast('Validation Error', 'Every landing source must have a landing number.', 'error');
            return;
        }

        const anyConflict = this.landingSources.some(s => s.warn);
        if (anyConflict) {
            this.showToast('Validation Error', 'Please resolve duplicate landing numbers in Step 4 before saving.', 'error');
            return;
        }

        this.isSaving = true;

        // ── Build SOQL dedup string ──────────────────────────────
        // Position-indexed conditions so custom logic numbers line up with rows.
        const condByPos = this.dedupRows.map(r => {
            if (!r.lhsField) return null;
            let rhs;
            if      (r.rhsType === 'mcube')  rhs = `:${r.rhsVal}`;
            else if (r.rhsType === 'static') rhs = `'${r.rhsVal}'`;
            else if (r.rhsType === 'lookup') {
                // If user picked a specific record, use its Id as a literal.
                // Otherwise fall back to a runtime-resolved bind variable.
                rhs = r.rhsVal ? `'${r.rhsVal}'` : `:lookupId_${r.lhsField}`;
            }
            return `${r.lhsField} = ${rhs}`;
        });
        const validConds   = condByPos.filter(Boolean);
        const selectFields = ['Id', ...new Set(this.dedupRows.filter(r => r.lhsField).map(r => r.lhsField))].join(', ');
        const selectClause = `SELECT ${selectFields} FROM ${this.curObj}`;

        let whereClause;
        if (this.dedupLogicType === 'any') {
            whereClause = validConds.join(' OR ');
        } else if (this.dedupLogicType === 'custom') {
            // Substitute each field number with its condition, preserving exactly
            // the AND/OR/parentheses the user typed. We never add parentheses here —
            // otherwise they would accumulate on every save/edit round-trip.
            whereClause = this.dedupCustomLogic.replace(/\d+/g, m => {
                const c = condByPos[parseInt(m, 10) - 1];
                return c ? c : m;
            });
        } else { // 'all'
            whereClause = validConds.join(' AND ');
        }
        const duplicationRule = `${selectClause} WHERE ${whereClause}`;

        const defaultValues = JSON.stringify(
            this.defaultRows
                .filter(r => r.field && r.value)
                .map(r => ({ field: r.field, value: r.value }))
        );
        const outboundFields = JSON.stringify(
            this.outboundRows
                .filter(r => r.field)
                .map((r, i) => ({ order: i + 1, field: r.field, label: r.label }))
        );

        const landingMap = {};
        this.landingSources.forEach(src => {
            const n = (src.number || '').trim();
            if (n) landingMap[src.source] = n;
        });
        const landingNumbers = JSON.stringify(landingMap);

        // Rich landing details (with campaign) → upserted to Mcube_Landing_Number__c
        const landingDetails = JSON.stringify(
            this.landingSources
                .filter(s => (s.number || '').trim() !== '')
                .map(s => ({
                    source:   s.source,
                    num:      (s.number || '').trim(),
                    campaign: (s.campaign || '').trim()
                }))
        );

        if (landingNumbers.length > 240) {
            this.showToast('Warning', 'Too many landing numbers — keep total under 255 characters.', 'warning');
            this.isSaving = false;
            return;
        }

        console.log('[MCube][Step6] ─── saveConfiguration (BOTH) ───');
        console.log('[MCube][Step6] sourceObject    :', this.curObj);
        console.log('[MCube][Step6] duplicationRule :', duplicationRule);
        console.log('[MCube][Step6] defaultValues   :', defaultValues);
        console.log('[MCube][Step6] landingNumbers  :', landingNumbers);
        console.log('[MCube][Step6] outboundFields  :', outboundFields);
        console.log('[MCube][Step6] isActive        :', this.isActive);
        console.log('[MCube][Step6] mode            :', this.isEditMode ? 'EDIT' : 'NEW');
        console.log('[MCube][Step6] ─────────────────────────────────');

        const wasEdit = this.isEditMode;

        Promise.resolve(
            saveConfig({
                configName      : `MCube - ${this.curObj}`,
                sourceObject    : this.curObj,
                duplicationRule : duplicationRule,
                defaultValues   : defaultValues,
                landingNumbers  : landingNumbers,
                landingDetails  : landingDetails,
                outboundFields  : outboundFields,
                callActivityMapping: this._buildCallActivityMapping(),
                createIfNotFound: true,
                isActive        : this.isActive,
                isDefault       : false,
                recordId        : this.recordId || null,
                configMode      : 'BOTH',
                priority        : this.priority
            })
        )
        .then(() => {
            this.isSaving = false;
            const action = wasEdit ? 'updated' : 'created';
            console.log(`[MCube][Step6] ✅ Configuration ${action} for:`, this.curObj);
            this.showToast(
                wasEdit ? 'Configuration Updated' : 'Configuration Created',
                `Configuration ${action} for ${this.curObj}.`,
                'success'
            );
            this.dispatchEvent(new CustomEvent('closemodal'));
        })
        .catch(err => {
            this.isSaving = false;
            console.error('[MCube][Step6] ❌ Save failed:', JSON.stringify(err));
            this.showToast('Save Failed', err?.body?.message || 'An unexpected error occurred.', 'error');
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    cancelAction() {
        this.dispatchEvent(new CustomEvent('closemodal'));
    }
}