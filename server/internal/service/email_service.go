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

// ConsoleEmailService prints codes to stdout and is only wired in dev mode
// without a Resend key: a production server must never log a sign-in code
type ConsoleEmailService struct{}

func (ConsoleEmailService) SendOTP(email, otp string) error {
	fmt.Printf("dev sign-in code: %s -> %s\n", email, otp)
	return nil
}

type ResendEmailService struct {
	APIKey string
	From   string
}

func NewResendEmailService(apiKey, from string) *ResendEmailService {
	return &ResendEmailService{APIKey: apiKey, From: from}
}

func (s *ResendEmailService) SendOTP(email, otp string) error {
	url := "https://api.resend.com/emails"
	payload := map[string]interface{}{
		"from":    s.From,
		"to":      email,
		"subject": "Your Miuchio Login Code",
		"html":    fmt.Sprintf("<strong>Your Miuchio login code is: %s</strong>. This code will expire in 5 minutes.", otp),
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
		// only the error name is logged: Resend messages can echo addresses
		var apiErr struct {
			Name string `json:"name"`
		}
		_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&apiErr)
		log.Printf("Resend API failed: status %d, error %q", resp.StatusCode, apiErr.Name)
		return fmt.Errorf("failed to send email: status code %d", resp.StatusCode)
	}

	return nil
}
