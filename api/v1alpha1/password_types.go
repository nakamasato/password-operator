/*
Copyright 2022.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type PasswordState string

const (
	PasswordInSync PasswordState = "InSync"
	PasswordFailed PasswordState = "Failed"
)

// EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!
// NOTE: json tags are required.  Any new fields you add must have json tags for the fields to be serialized.

// PasswordSpec defines the desired state of Password
type PasswordSpec struct {
	//+kubebuilder:validation:Minimum=8
	//+kubebuilder:default:=20
	//+kubebuilder:validation:Required
	Length int `json:"length"`

	//+kubebuilder:validation:Minimum=0
	//+kubebuilder:default:=10
	//+kubebuilder:validation:Optional
	Digit int `json:"digit"`

	//+kubebuilder:validation:Minimum=0
	//+kubebuilder:default:=10
	//+kubebuilder:validation:Optional
	Symbol int `json:"symbol"`

	//+kubebuilder:default:=false
	//+kubebuilder:validation:Optional
	CaseSensitive bool `json:"caseSensitive"`
	//+kubebuilder:default:=false
	//+kubebuilder:validation:Optional
	DisallowRepeat bool `json:"disallowRepeat"`
}

// PasswordStatus defines the observed state of Password
type PasswordStatus struct {

	// Information about if Password is in-sync.
	State PasswordState `json:"state,omitempty"` // in-sync, failed
}

//+kubebuilder:object:root=true
//+kubebuilder:subresource:status
//+kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
//+kubebuilder:printcolumn:name="State",type=string,JSONPath=`.status.state`

// Password is the Schema for the passwords API
type Password struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   PasswordSpec   `json:"spec,omitempty"`
	Status PasswordStatus `json:"status,omitempty"`
}

//+kubebuilder:object:root=true

// PasswordList contains a list of Password
type PasswordList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Password `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Password{}, &PasswordList{})
}
