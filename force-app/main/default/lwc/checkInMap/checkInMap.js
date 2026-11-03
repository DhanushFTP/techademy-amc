import { LightningElement, api, wire } from 'lwc';
import getCheckInsForParent           from '@salesforce/apex/CheckInMapController.getCheckInsForParent';
import { ShowToastEvent }            from 'lightning/platformShowToastEvent';

export default class CheckInMap extends LightningElement {
  @api recordId;
  mapMarkers = [];
  centerLocation;  // new property for the map center

  @wire(getCheckInsForParent, { parentId: '$recordId' })
  wiredChecks({ error, data }) {
    if (data) {
      this.mapMarkers = data;
      // If we have at least one marker, set it as the center
      if (data.length > 0) {
        this.centerLocation = data[0].location;
      } else {
        this.centerLocation = null;
      }
    } else if (error) {
      this.dispatchEvent(new ShowToastEvent({
        title:   'Error loading map',
        message: error.body?.message || error.message,
        variant: 'error'
      }));
    }
  }
}