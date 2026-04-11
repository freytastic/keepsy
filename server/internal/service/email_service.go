package service

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
)

type EmailService interface {
	SendOTP(email, otp string) error
}

type ResendEmailService struct {
	APIKey string
}

func NewResendEmailService(apiKey string) *ResendEmailService {
	return &ResendEmailService{APIKey: apiKey}
}

func (s *ResendEmailService) SendOTP(email, otp string) error {
	if s.APIKey == "" {
		// for testing
		fmt.Printf("RESEND_API_KEY not set. Printing OTP to console: %s -> %s\n", email, otp)
		return nil
	}

	url := "https://api.resend.com/emails"
	payload := map[string]interface{}{
		"from":    "Keepsy <onboarding@resend.dev>",
		"to":      email,
		"subject": "Your Keepsy Login Code",
		"html":    fmt.Sprintf("<strong>Your Keepsy login code is: %s</strong>. This code will expire in 5 minutes.", otp),
	}

	jsonPayload, _ := json.Marshal(payload)
	req, _ := http.NewRequest("POST", url, bytes.NewBuffer(jsonPayload))
	req.Header.Set("Authorization", "Bearer "+s.APIKey)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		log.Printf("Resend API failed: Status %d, Body: %s", resp.StatusCode, string(body))
		return fmt.Errorf("failed to send email: status code %d", resp.StatusCode)
	}

	return nil
}
