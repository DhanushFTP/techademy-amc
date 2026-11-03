import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent }              from 'lightning/platformShowToastEvent';
import { loadScript, loadStyle }       from 'lightning/platformResourceLoader';
import LEAFLET                         from '@salesforce/resourceUrl/leaflet';
import getTrackingData                 from '@salesforce/apex/LocationTrackingController.getTrackingData';

export default class RouteMapViewer extends LightningElement {
    @api recordId; // User record Id from the record page
    @track selectedDate = '';
    @track isLoading = false;
    @track hasData = false;
    @track formattedStartTime = '';
    @track formattedEndTime = '';
    @track pointCount = 0;

    leafletInitialized = false;
    map = null;
    routeLayer = null;

    get todayDate() {
        return new Date().toISOString().split('T')[0];
    }

    renderedCallback() {
        if (this.leafletInitialized) return;
        this.leafletInitialized = true;

        Promise.all([
            loadScript(this, LEAFLET + '/leaflet.js'),
            loadStyle(this, LEAFLET + '/leaflet.css')
        ])
        .then(() => {
            // Leaflet loaded successfully
        })
        .catch(error => {
            this.showToast('Error', 'Failed to load map library: ' + error.message, 'error');
        });
    }

    handleDateChange(event) {
        this.selectedDate = event.target.value;
        if (this.selectedDate && this.recordId) {
            this.fetchRouteData();
        }
    }

    fetchRouteData() {
        this.isLoading = true;
        this.hasData = false;

        getTrackingData({ userId: this.recordId, trackingDate: this.selectedDate })
            .then(result => {
                if (result.hasData && result.points && result.points.length > 0) {
                    this.hasData = true;
                    this.pointCount = result.points.length;
                    this.formattedStartTime = result.startTime
                        ? new Date(result.startTime).toLocaleTimeString() : 'N/A';
                    this.formattedEndTime = result.endTime
                        ? new Date(result.endTime).toLocaleTimeString() : 'Still active';

                    // Render map after DOM updates
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => { this.renderMap(result.points); }, 100);
                } else {
                    this.hasData = false;
                    this.destroyMap();
                }
            })
            .catch(error => {
                const msg = error.body?.message || error.message || JSON.stringify(error);
                this.showToast('Error', msg, 'error');
                this.hasData = false;
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    renderMap(points) {
        const container = this.template.querySelector('.map-container');
        if (!container) return;

        // Destroy previous map instance
        this.destroyMap();

        // eslint-disable-next-line no-undef
        const L = window.L;
        if (!L) {
            this.showToast('Error', 'Map library not loaded.', 'error');
            return;
        }

        // Initialize map
        this.map = L.map(container);

        // OpenStreetMap tiles (free)
        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
            attribution: '&copy; OpenStreetMap contributors',
            maxZoom: 19
        }).addTo(this.map);

        // Build route coordinates
        const latlngs = points.map(p => [Number(p.lat), Number(p.lng)]);

        // Route polyline (blue)
        const polyline = L.polyline(latlngs, {
            color: '#1589EE',
            weight: 4,
            opacity: 0.8
        }).addTo(this.map);

        // Start marker (green)
        const startIcon = L.divIcon({
            html: '<div style="background:#04844B;width:16px;height:16px;border-radius:50%;border:3px solid white;box-shadow:0 2px 4px rgba(0,0,0,0.3);"></div>',
            iconSize: [16, 16],
            className: ''
        });
        L.marker(latlngs[0], { icon: startIcon })
            .addTo(this.map)
            .bindPopup('<b>Start</b><br/>' + this.formatTimestamp(points[0].timestamp));

        // End marker (red)
        const endIdx = latlngs.length - 1;
        const endIcon = L.divIcon({
            html: '<div style="background:#C23934;width:16px;height:16px;border-radius:50%;border:3px solid white;box-shadow:0 2px 4px rgba(0,0,0,0.3);"></div>',
            iconSize: [16, 16],
            className: ''
        });
        L.marker(latlngs[endIdx], { icon: endIcon })
            .addTo(this.map)
            .bindPopup('<b>End</b><br/>' + this.formatTimestamp(points[endIdx].timestamp));

        // Intermediate point markers (small blue dots)
        for (let i = 1; i < endIdx; i++) {
            const dotIcon = L.divIcon({
                html: '<div style="background:#1589EE;width:8px;height:8px;border-radius:50%;border:2px solid white;box-shadow:0 1px 2px rgba(0,0,0,0.2);"></div>',
                iconSize: [8, 8],
                className: ''
            });
            L.marker(latlngs[i], { icon: dotIcon })
                .addTo(this.map)
                .bindPopup(this.formatTimestamp(points[i].timestamp));
        }

        // Fit map to route bounds
        this.map.fitBounds(polyline.getBounds().pad(0.1));
    }

    formatTimestamp(ts) {
        if (!ts) return '';
        return new Date(ts).toLocaleTimeString();
    }

    destroyMap() {
        if (this.map) {
            this.map.remove();
            this.map = null;
        }
    }

    showToast(title, message, variant, mode = 'dismissable') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}