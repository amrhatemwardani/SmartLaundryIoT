// Register this file at the website root. Firebase web settings are public client configuration.
self.addEventListener('notificationclick',event=>{event.notification.close();event.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(list=>{for(const client of list){if('focus'in client)return client.focus()}return clients.openWindow('/student.html')}))});
importScripts('https://www.gstatic.com/firebasejs/13.3.0/firebase-app-compat.js','https://www.gstatic.com/firebasejs/13.3.0/firebase-messaging-compat.js');
const config={apiKey:'AIzaSyCDoQice3hZD13F0mxKnvlJs_0hbGKvzco',authDomain:'smart-laundry-7d609.firebaseapp.com',projectId:'smart-laundry-7d609',storageBucket:'smart-laundry-7d609.firebasestorage.app',messagingSenderId:'887837444072',appId:'1:887837444072:web:92d7c38086bd88f747465d',measurementId:'G-T5KZE1YTGC'};
if(config.apiKey&&config.projectId){firebase.initializeApp(config);firebase.messaging()}
